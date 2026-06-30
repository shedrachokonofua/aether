# =============================================================================
# mnemo — personal memory service
# =============================================================================
# Elixir/Phoenix app ingesting OpenWebUI, Matrix, and email into a unified
# message model with RAG, API, and MCP transport.
# Docs: ../mnemo/docs/HANDOFF.md, ../mnemo/docs/DEPLOYMENT.md

locals {
  mnemo_namespace  = kubernetes_namespace_v1.infra.metadata[0].name
  mnemo_host       = "mnemo.home.shdr.ch"
  mnemo_image      = "registry.gitlab.home.shdr.ch/so/mnemo:latest"
  mnemo_port       = 4000
  mnemo_cnpg       = "mnemo-cnpg"
  mnemo_db         = "mnemo"
  mnemo_db_user    = "mnemo"
  mnemo_db_service = "${local.mnemo_cnpg}-rw.${local.mnemo_namespace}.svc.cluster.local"
  mnemo_db_url     = "postgresql://${local.mnemo_db_user}:${kubernetes_secret_v1.mnemo_cnpg_app.data["password"]}@${local.mnemo_db_service}:5432/${local.mnemo_db}?sslmode=disable"

  mnemo_seaweed_endpoint = "https://s3.seaweed.home.shdr.ch"
  mnemo_seaweed_bucket   = "mnemo-objects"

  mnemo_labels = { app = "mnemo" }
}

# --- Secrets -----------------------------------------------------------------

resource "kubernetes_secret_v1" "mnemo_env" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "mnemo-env"
    namespace = local.mnemo_namespace
    labels    = local.mnemo_labels
  }

  data = {
    DATABASE_URL              = local.mnemo_db_url
    SECRET_KEY_BASE           = var.secrets["mnemo.secret_key_base"]
    PHX_HOST                  = local.mnemo_host
    PHX_SERVER                = "true"

    # Seaweed S3 object storage
    SEAWEED_S3_ENDPOINT       = local.mnemo_seaweed_endpoint
    SEAWEED_S3_BUCKET         = local.mnemo_seaweed_bucket
    SEAWEED_S3_ACCESS_KEY     = var.secrets["seaweedfs.s3_admin_access_key"]
    SEAWEED_S3_SECRET_KEY     = var.secrets["seaweedfs.s3_admin_secret_key"]

    # LiteLLM embeddings
    LITELLM_EMBEDDING_BASE_URL = "http://litellm.${local.mnemo_namespace}.svc.cluster.local:4000"
    LITELLM_EMBEDDING_API_KEY  = var.secrets["litellm.master_key"]

    # OpenWebUI source (read-only API access)
    OPENWEBUI_DATABASE_URL     = "postgresql://openwebui:${kubernetes_secret_v1.openwebui_cnpg_app.data["password"]}@openwebui-cnpg-rw.${local.mnemo_namespace}.svc.cluster.local:5432/openwebui?sslmode=disable"
    OPENWEBUI_API_KEY          = var.secrets["openwebui.mcpo_api_key"]

    # Matrix source (bot user access token)
    MATRIX_HOMESERVER_URL      = "https://${local.mnemo_host}"
    MATRIX_ACCESS_TOKEN        = var.secrets["matrix.mnemo_bot_access_token"]

    # Gmail source (OAuth refresh token)
    GMAIL_CLIENT_ID            = var.secrets["gmail.client_id"]
    GMAIL_CLIENT_SECRET        = var.secrets["gmail.client_secret"]
    GMAIL_REFRESH_TOKEN        = var.secrets["gmail.refresh_token"]

    # OTEL (Aether in-cluster collector)
    OTEL_SERVICE_NAME          = "mnemo"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-daemonset-opentelemetry-collector.system.svc.cluster.local:4317"
    OTEL_RESOURCE_ATTRIBUTES   = "service.namespace=mnemo,deployment.environment=home"
  }

  type = "Opaque"
}

# CNPG app secret (username/password for the mnemo CNPG cluster)
resource "kubernetes_secret_v1" "mnemo_cnpg_app" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "mnemo-cnpg-app"
    namespace = local.mnemo_namespace
    labels    = local.mnemo_labels
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.mnemo_db_user
    password = var.secrets["mnemo.database_password"]
  }
}

# --- CNPG Postgres Cluster ---------------------------------------------------

resource "kubectl_manifest" "mnemo_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.mnemo_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.mnemo_cnpg
      namespace = local.mnemo_namespace
      labels    = local.mnemo_labels
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:16.13"
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      bootstrap = {
        initdb = {
          database = local.mnemo_db
          owner    = local.mnemo_db_user
          secret = {
            name = kubernetes_secret_v1.mnemo_cnpg_app.metadata[0].name
          }
        }
      }
      postgresql = {
        parameters = {
          # Enable pgvector, pg_trgm, unaccent (required by Phase 1 schema)
          shared_preload_libraries = "vector"
        }
      }
    }
  })
}

# --- Deployment --------------------------------------------------------------

resource "kubernetes_deployment_v1" "mnemo" {
  depends_on = [
    kubectl_manifest.mnemo_cnpg_cluster,
    kubernetes_secret_v1.mnemo_env,
  ]

  metadata {
    name      = "mnemo"
    namespace = local.mnemo_namespace
    labels    = local.mnemo_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.mnemo_labels
    }

    template {
      metadata {
        labels = local.mnemo_labels
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = tostring(local.mnemo_port)
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        container {
          name  = "mnemo"
          image = local.mnemo_image

          port {
            container_port = local.mnemo_port
            name           = "http"
            protocol       = "TCP"
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mnemo_env.metadata[0].name
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          liveness_probe {
            http_get {
              path = "/health/live"
              port = local.mnemo_port
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health/ready"
              port = local.mnemo_port
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }
        }
      }
    }
  }
}

# --- Service -----------------------------------------------------------------

resource "kubernetes_service_v1" "mnemo" {
  depends_on = [kubernetes_deployment_v1.mnemo]

  metadata {
    name      = "mnemo"
    namespace = local.mnemo_namespace
    labels    = local.mnemo_labels
  }

  spec {
    selector = local.mnemo_labels

    port {
      port        = local.mnemo_port
      target_port = local.mnemo_port
      protocol    = "TCP"
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# --- HTTPRoute ---------------------------------------------------------------

resource "kubernetes_manifest" "mnemo_route" {
  depends_on = [
    kubernetes_manifest.main_gateway,
    kubernetes_service_v1.mnemo,
  ]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "mnemo"
      namespace = local.mnemo_namespace
      labels    = local.mnemo_labels
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.mnemo_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.mnemo.metadata[0].name
          port = local.mnemo_port
        }]
      }]
    }
  }
}

# --- DB Backup Target --------------------------------------------------------

resource "kubectl_manifest" "mnemo_db_backup" {
  depends_on = [kubectl_manifest.mnemo_cnpg_cluster]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "mnemo-db-backup"
      namespace = local.mnemo_namespace
    }
    spec = {
      schedule = "0 2 * * *"  # Daily at 2am
      backupOwnerReference = "self"
      cluster = {
        name = local.mnemo_cnpg
      }
    }
  })
}
