# =============================================================================
# Hoppscotch — API Testing Platform
# =============================================================================
# Stack: Hoppscotch main app + Proxyscotch relay + Postgres.
#
# Data migration: postgres_data bind-mount at
#   /etc/dokploy/compose/default-hoppscotch-atazkg/postgres_data/ → 47 MB
# Run pg_dump inside the Dokploy container, restore into k8s postgres.
#
# Security: POSTGRES_PASSWORD was hardcoded 'hoppscotchpass' in Dokploy.
# New password is Tofu-generated below.

resource "kubernetes_namespace_v1" "hoppscotch" {
  depends_on = [helm_release.cilium]
  metadata { name = "hoppscotch" }
}

resource "random_password" "hoppscotch_postgres_password" {
  length  = 32
  special = false
}
resource "random_password" "hoppscotch_jwt_secret" {
  length  = 32
  special = false
}
resource "random_password" "hoppscotch_session_secret" {
  length  = 32
  special = false
}
resource "random_password" "hoppscotch_data_encryption_key" {
  length  = 32
  special = false
}

locals {
  hoppscotch_image       = "hoppscotch/hoppscotch:latest"
  hoppscotch_proxy_image = "hoppscotch/proxyscotch"
  hoppscotch_pg_image    = "postgres:15-alpine"

  hoppscotch_host       = "hoppscotch.home.shdr.ch"
  hoppscotch_proxy_host = "proxyscotch.home.shdr.ch"

  hoppscotch_port       = 80
  hoppscotch_proxy_port = 9159
  hoppscotch_pg_port    = 5432

  hoppscotch_ns           = kubernetes_namespace_v1.hoppscotch.metadata[0].name
  hoppscotch_labels       = { app = "hoppscotch" }
  hoppscotch_proxy_labels = { app = "proxyscotch" }
  hoppscotch_pg_labels    = { app = "hoppscotch-postgres" }
}

resource "kubernetes_secret_v1" "hoppscotch_postgres" {
  depends_on = [kubernetes_namespace_v1.hoppscotch]
  metadata {
    name      = "hoppscotch-postgres"
    namespace = local.hoppscotch_ns
  }
  data = {
    POSTGRES_USER     = "hoppscotch"
    POSTGRES_PASSWORD = random_password.hoppscotch_postgres_password.result
    POSTGRES_DB       = "hoppscotch"
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "hoppscotch_env" {
  depends_on = [kubernetes_namespace_v1.hoppscotch]
  metadata {
    name      = "hoppscotch-env"
    namespace = local.hoppscotch_ns
  }
  data = {
    DATABASE_URL            = "postgresql://hoppscotch:${random_password.hoppscotch_postgres_password.result}@hoppscotch-postgres.${local.hoppscotch_ns}.svc.cluster.local:${local.hoppscotch_pg_port}/hoppscotch"
    JWT_SECRET              = random_password.hoppscotch_jwt_secret.result
    SESSION_SECRET          = random_password.hoppscotch_session_secret.result
    DATA_ENCRYPTION_KEY     = random_password.hoppscotch_data_encryption_key.result
    TOKEN_SALT_COMPLEXITY   = "10"
    MAGIC_LINK_TOKEN_VALIDITY  = "3"
    REFRESH_TOKEN_VALIDITY     = "604800000"
    ACCESS_TOKEN_VALIDITY      = "86400000"
    ALLOW_SECURE_COOKIES       = "true"
    REDIRECT_URL               = "https://${local.hoppscotch_host}"
    WHITELISTED_ORIGINS        = "https://${local.hoppscotch_host},app://localhost_3200,app://hoppscotch"
    VITE_ALLOWED_AUTH_PROVIDERS = "EMAIL"
    MAILER_SMTP_ENABLE         = "false"
    MAILER_USE_CUSTOM_CONFIGS  = "false"
    MAILER_ADDRESS_FROM        = "noreply@${local.hoppscotch_host}"
    MAILER_SMTP_URL            = "smtp://localhost:587"
    RATE_LIMIT_TTL             = "60"
    RATE_LIMIT_MAX             = "100"
    VITE_BASE_URL              = "https://${local.hoppscotch_host}"
    VITE_SHORTCODE_BASE_URL    = "https://${local.hoppscotch_host}"
    VITE_ADMIN_URL             = "https://${local.hoppscotch_host}/admin"
    VITE_BACKEND_GQL_URL       = "https://${local.hoppscotch_host}/backend/graphql"
    VITE_BACKEND_WS_URL        = "wss://${local.hoppscotch_host}/backend/graphql"
    VITE_BACKEND_API_URL       = "https://${local.hoppscotch_host}/backend/v1"
    ENABLE_SUBPATH_BASED_ACCESS = "true"
  }
  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "hoppscotch_postgres_data" {
  depends_on = [kubernetes_namespace_v1.hoppscotch, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name      = "hoppscotch-postgres-data"
    namespace = local.hoppscotch_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_stateful_set_v1" "hoppscotch_postgres" {
  depends_on = [kubernetes_secret_v1.hoppscotch_postgres, kubernetes_persistent_volume_claim_v1.hoppscotch_postgres_data]
  metadata {
    name      = "hoppscotch-postgres"
    namespace = local.hoppscotch_ns
    labels    = local.hoppscotch_pg_labels
  }
  spec {
    service_name = "hoppscotch-postgres"
    replicas     = 1
    selector { match_labels = local.hoppscotch_pg_labels }
    template {
      metadata { labels = local.hoppscotch_pg_labels }
      spec {
        container {
          name  = "postgres"
          image = local.hoppscotch_pg_image
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.hoppscotch_postgres.metadata[0].name
            }
          }
          env {
            name = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port { container_port = local.hoppscotch_pg_port }
          volume_mount {
            name = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          readiness_probe {
            exec { command = ["/bin/sh", "-c", "pg_isready -U hoppscotch -d hoppscotch"] }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.hoppscotch_postgres_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "hoppscotch_postgres" {
  depends_on = [kubernetes_stateful_set_v1.hoppscotch_postgres]
  metadata {
    name      = "hoppscotch-postgres"
    namespace = local.hoppscotch_ns
    labels    = local.hoppscotch_pg_labels
  }
  spec {
    selector = local.hoppscotch_pg_labels
    port {
      port = local.hoppscotch_pg_port
      target_port = local.hoppscotch_pg_port
    }
    type = "ClusterIP"
  }
}

# Migration job — runs prisma db push before the server starts; idempotent
resource "kubernetes_job_v1" "hoppscotch_migration" {
  depends_on = [kubernetes_service_v1.hoppscotch_postgres, kubernetes_secret_v1.hoppscotch_env]

  metadata {
    name      = "hoppscotch-migration"
    namespace = local.hoppscotch_ns
  }

  spec {
    backoff_limit              = 4
    ttl_seconds_after_finished = 86400

    template {
      metadata { labels = { app = "hoppscotch-migration" } }
      spec {
        restart_policy = "OnFailure"
        container {
          name  = "migrate"
          image = local.hoppscotch_image

          command = ["/bin/sh", "-c", "cd /dist/backend && npx prisma migrate deploy --schema prisma/schema.prisma"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.hoppscotch_env.metadata[0].name
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }

  lifecycle { ignore_changes = [spec[0].template] }
}

resource "kubernetes_deployment_v1" "hoppscotch" {
  depends_on = [kubernetes_job_v1.hoppscotch_migration, kubernetes_secret_v1.hoppscotch_env]
  metadata {
    name      = "hoppscotch"
    namespace = local.hoppscotch_ns
    labels    = local.hoppscotch_labels
  }
  spec {
    replicas = 1
    selector { match_labels = local.hoppscotch_labels }
    template {
      metadata { labels = local.hoppscotch_labels }
      spec {
        enable_service_links = false
        container {
          name  = "hoppscotch"
          image = local.hoppscotch_image
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.hoppscotch_env.metadata[0].name
            }
          }
          port {
            container_port = local.hoppscotch_port
            name = "http"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = local.hoppscotch_port
            }
            initial_delay_seconds = 30
            period_seconds        = 15
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "hoppscotch" {
  metadata {
    name      = "hoppscotch"
    namespace = local.hoppscotch_ns
    labels    = local.hoppscotch_labels
  }
  spec {
    selector = local.hoppscotch_labels
    port {
      port = local.hoppscotch_port
      target_port = local.hoppscotch_port
      name = "http"
    }
  }
}

resource "kubernetes_deployment_v1" "proxyscotch" {
  depends_on = [kubernetes_namespace_v1.hoppscotch]
  metadata {
    name      = "proxyscotch"
    namespace = local.hoppscotch_ns
    labels    = local.hoppscotch_proxy_labels
  }
  spec {
    replicas = 1
    selector { match_labels = local.hoppscotch_proxy_labels }
    template {
      metadata { labels = local.hoppscotch_proxy_labels }
      spec {
        enable_service_links = false
        container {
          name  = "proxyscotch"
          image = local.hoppscotch_proxy_image
          port {
            container_port = local.hoppscotch_proxy_port
            name = "http"
          }
          resources {
            requests = { cpu = "30m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "proxyscotch" {
  metadata {
    name      = "proxyscotch"
    namespace = local.hoppscotch_ns
    labels    = local.hoppscotch_proxy_labels
  }
  spec {
    selector = local.hoppscotch_proxy_labels
    port {
      port = local.hoppscotch_proxy_port
      target_port = local.hoppscotch_proxy_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "hoppscotch_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.hoppscotch]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "hoppscotch", namespace = local.hoppscotch_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.hoppscotch_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "hoppscotch", port = local.hoppscotch_port }]
      }]
    }
  }
}

resource "kubernetes_manifest" "proxyscotch_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.proxyscotch]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "proxyscotch", namespace = local.hoppscotch_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.hoppscotch_proxy_host]
      rules      = [{ backendRefs = [{ name = "proxyscotch", port = local.hoppscotch_proxy_port }] }]
    }
  }
}
