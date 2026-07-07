# =============================================================================
# LiteLLM — LLM Gateway + MCP
# =============================================================================
# Migrated from the legacy Podman VM to Kubernetes.

locals {
  litellm_image               = "ghcr.io/berriai/litellm:1.86.2"
  litellm_espn_mcp_image      = "registry.gitlab.home.shdr.ch/so/espn-mcp:latest"
  litellm_postgres_image      = "docker.io/postgres:18"
  litellm_finviz_image        = "registry.gitlab.home.shdr.ch/shdrch/finviz-mcp-server/main:latest"
  litellm_coingecko_image     = "docker.io/node:22-slim"
  litellm_time_mcp_image      = "docker.io/theo01/mcp-time:latest"
  litellm_google_maps_image   = "docker.io/node:22-slim"
  litellm_google_maps_package = "@cablate/mcp-google-map@0.0.52"
  litellm_affine_mcp_image    = "ghcr.io/dawncr0w/affine-mcp-server:latest"
  litellm_host                = "litellm.home.shdr.ch"
  litellm_espn_mcp_host       = "espn-mcp.home.shdr.ch"
  litellm_ns                  = module.namespace["litellm"].name
  litellm_labels              = { app = "litellm" }
  litellm_port                = 4000
  litellm_finviz_port         = 8000
  litellm_coingecko_port      = 8002
  litellm_time_mcp_port       = 8003
  litellm_google_maps_port    = 8004
  litellm_affine_mcp_port     = 8005
  litellm_espn_mcp_port       = 8080
  litellm_postgres_port       = 5432
  litellm_cnpg_cluster        = "litellm-cnpg"
  litellm_db_host             = "${local.litellm_cnpg_cluster}-rw.${local.litellm_ns}.svc.cluster.local"
  litellm_affine_workspace_id = "5e3fe4c1-8c87-489b-95a5-77daa164a836"
  litellm_config_yaml = templatefile("${path.module}/litellm_config.yaml.tftpl", {
    affine_mcp_http_token = random_password.litellm_affine_mcp_http.result
    google_maps_enabled   = var.litellm_google_maps_enabled
  })
  litellm_database_url  = "postgres://${var.secrets["litellm.database_user"]}:${var.secrets["litellm.database_password"]}@${local.litellm_db_host}/litellm?sslmode=disable"
  litellm_registry_host = "registry.gitlab.home.shdr.ch"
  litellm_registry_user = var.secrets["gitlab.root_email"]
  litellm_registry_pass = var.secrets["gitlab.root_password"]
}

resource "kubernetes_secret_v1" "litellm_env" {
  depends_on = [module.namespace["infra"]]

  metadata {
    name      = "litellm-env"
    namespace = local.litellm_ns
  }

  data = merge(
    {
      LITELLM_MASTER_KEY    = var.secrets["litellm.master_key"]
      DATABASE_URL          = local.litellm_database_url
      POSTGRES_DB           = "litellm"
      POSTGRES_USER         = var.secrets["litellm.database_user"]
      POSTGRES_PASSWORD     = var.secrets["litellm.database_password"]
      OPENAI_API_KEY        = var.secrets["litellm.openai_api_key"]
      ANTHROPIC_API_KEY     = var.secrets["litellm.anthropic_api_key"]
      OPENROUTER_API_KEY    = var.secrets["litellm.openrouter_api_key"]
      OLLAMA_API_KEY        = var.secrets["litellm.ollama_cloud_api_key"]
      CLINEPASS_API_KEY     = var.secrets["litellm.clinepass_api_key"]
      XIAOMI_API_KEY        = var.secrets["litellm.xiaomi_api_key"]
      ALIBABA_API_KEY       = var.secrets["litellm.alibaba_api_key"]
      ZAI_API_KEY           = var.secrets["litellm.zai_api_key"]
      CURSOR_API_KEY        = var.secrets["composer.cursor_api_key"]
      FINVIZ_API_KEY        = var.secrets["finviz_api_key"]
      COINGECKO_API_KEY     = var.secrets["coingecko_api_key"]
      AFFINE_API_TOKEN      = var.secrets["litellm.affine_api_token"]
      AFFINE_MCP_HTTP_TOKEN = random_password.litellm_affine_mcp_http.result
      LITELLM_CONFIG_SHA    = sha256(local.litellm_config_yaml)
    },
    var.litellm_google_maps_enabled ? {
      GOOGLE_MAPS_API_KEY = var.litellm_google_maps_api_key
    } : {}
  )

  type = "Opaque"
}

resource "random_password" "litellm_affine_mcp_http" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "litellm_config" {
  depends_on = [module.namespace["infra"]]

  metadata {
    name      = "litellm-config"
    namespace = local.litellm_ns
  }

  data = {
    "config.yaml" = local.litellm_config_yaml
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "litellm_gitlab_registry" {
  depends_on = [module.namespace["infra"]]

  metadata {
    name      = "litellm-gitlab-registry"
    namespace = local.litellm_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.litellm_registry_host) = {
          username = local.litellm_registry_user
          password = local.litellm_registry_pass
          auth     = base64encode("${local.litellm_registry_user}:${local.litellm_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_persistent_volume_claim_v1" "litellm_postgres_data" {
  depends_on = [module.namespace["infra"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "litellm-postgres-data"
    namespace = local.litellm_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "litellm" {
  depends_on = [
    kubectl_manifest.litellm_cnpg_cluster,
    kubernetes_secret_v1.litellm_env,
    kubernetes_secret_v1.litellm_config,
    kubernetes_secret_v1.litellm_gitlab_registry,
  ]

  metadata {
    name      = "litellm"
    namespace = local.litellm_ns
    labels    = local.litellm_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.litellm_labels
    }

    template {
      metadata {
        labels = local.litellm_labels
        annotations = {
          "aether.shdr.ch/config-sha"       = sha256(local.litellm_config_yaml)
          "aether.shdr.ch/database-url-sha" = sha256(local.litellm_database_url)
          "aether.shdr.ch/env-sha"          = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.litellm_env.data)))
        }
      }

      spec {
        enable_service_links = false

        image_pull_secrets {
          name = kubernetes_secret_v1.litellm_gitlab_registry.metadata[0].name
        }

        container {
          name  = "litellm"
          image = local.litellm_image
          args  = ["--config", "/app/config.yaml", "--detailed_debug"]

          port {
            container_port = local.litellm_port
            name           = "http"
          }

          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "LITELLM_MASTER_KEY"
              }
            }
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }

          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }

          env {
            name = "ANTHROPIC_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ANTHROPIC_API_KEY"
              }
            }
          }

          env {
            name = "OPENROUTER_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OPENROUTER_API_KEY"
              }
            }
          }

          env {
            name = "OLLAMA_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OLLAMA_API_KEY"
              }
            }
          }

          env {
            name = "CLINEPASS_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "CLINEPASS_API_KEY"
              }
            }
          }

          env {
            name = "XIAOMI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "XIAOMI_API_KEY"
              }
            }
          }

          env {
            name = "ALIBABA_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ALIBABA_API_KEY"
              }
            }
          }

          env {
            name = "ZAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ZAI_API_KEY"
              }
            }
          }

          env {
            name = "CURSOR_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "CURSOR_API_KEY"
              }
            }
          }

          env {
            name = "LITELLM_CONFIG_SHA"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "LITELLM_CONFIG_SHA"
              }
            }
          }

          readiness_probe {
            http_get {
              path = "/health/liveliness"
              port = local.litellm_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 12
          }

          liveness_probe {
            http_get {
              path = "/health/liveliness"
              port = local.litellm_port
            }
            initial_delay_seconds = 90
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "4000m"
              memory = "4Gi"
            }
          }

          volume_mount {
            name       = "litellm-config"
            mount_path = "/app/config.yaml"
            sub_path   = "config.yaml"
            read_only  = true
          }
        }

        container {
          name  = "finviz-mcp-server"
          image = local.litellm_finviz_image

          port {
            container_port = local.litellm_finviz_port
            name           = "finviz"
          }

          env {
            name  = "MCP_TRANSPORT"
            value = "streamable-http"
          }

          env {
            name  = "MCP_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "MCP_PORT"
            value = tostring(local.litellm_finviz_port)
          }

          env {
            name = "FINVIZ_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "FINVIZ_API_KEY"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        container {
          name    = "coingecko-mcp-server"
          image   = local.litellm_coingecko_image
          command = ["npx", "-y", "@coingecko/coingecko-mcp", "--transport", "http", "--port", tostring(local.litellm_coingecko_port)]

          port {
            container_port = local.litellm_coingecko_port
            name           = "coingecko"
          }

          env {
            name = "COINGECKO_DEMO_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "COINGECKO_API_KEY"
              }
            }
          }

          env {
            name  = "COINGECKO_ENVIRONMENT"
            value = "demo"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }

        container {
          name  = "time-mcp-server"
          image = local.litellm_time_mcp_image
          args  = ["--transport", "stream", "--address", "http://0.0.0.0:${local.litellm_time_mcp_port}/mcp"]

          port {
            container_port = local.litellm_time_mcp_port
            name           = "time-mcp"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        dynamic "container" {
          for_each = var.litellm_google_maps_enabled ? [1] : []

          content {
            name    = "google-maps-mcp-server"
            image   = local.litellm_google_maps_image
            command = ["npx", "-y", local.litellm_google_maps_package, "--host", "0.0.0.0", "--port", tostring(local.litellm_google_maps_port)]

            port {
              container_port = local.litellm_google_maps_port
              name           = "google-maps"
            }

            env {
              name = "GOOGLE_MAPS_API_KEY"
              value_from {
                secret_key_ref {
                  name = kubernetes_secret_v1.litellm_env.metadata[0].name
                  key  = "GOOGLE_MAPS_API_KEY"
                }
              }
            }

            resources {
              requests = {
                cpu    = "50m"
                memory = "512Mi"
              }
              limits = {
                cpu    = "500m"
                memory = "1Gi"
              }
            }
          }
        }

        container {
          name  = "affine-mcp-server"
          image = local.litellm_affine_mcp_image

          port {
            container_port = local.litellm_affine_mcp_port
            name           = "affine-mcp"
          }

          env {
            name  = "MCP_TRANSPORT"
            value = "http"
          }

          env {
            name  = "PORT"
            value = tostring(local.litellm_affine_mcp_port)
          }

          env {
            name  = "AFFINE_MCP_HTTP_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "AFFINE_MCP_AUTH_MODE"
            value = "bearer"
          }

          env {
            name  = "AFFINE_BASE_URL"
            value = "https://${local.affine_host}"
          }

          env {
            name  = "AFFINE_WORKSPACE_ID"
            value = local.litellm_affine_workspace_id
          }

          env {
            name = "AFFINE_API_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "AFFINE_API_TOKEN"
              }
            }
          }

          env {
            name = "AFFINE_MCP_HTTP_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "AFFINE_MCP_HTTP_TOKEN"
              }
            }
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = local.litellm_affine_mcp_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.litellm_affine_mcp_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        container {
          name    = "espn-mcp"
          image   = local.litellm_espn_mcp_image
          command = ["espn-mcp", "--http", "8080"]

          port {
            name           = "espn-mcp"
            container_port = local.litellm_espn_mcp_port
            protocol       = "TCP"
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.litellm_espn_mcp_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.litellm_espn_mcp_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "litellm-config"
          secret {
            secret_name = kubernetes_secret_v1.litellm_config.metadata[0].name
          }
        }
      }
    }
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

resource "kubernetes_service_v1" "litellm" {
  depends_on = [kubernetes_deployment_v1.litellm]

  metadata {
    name      = "litellm"
    namespace = local.litellm_ns
    labels    = local.litellm_labels
  }

  spec {
    selector = local.litellm_labels

    port {
      port        = local.litellm_port
      target_port = local.litellm_port
      name        = "http"
    }
  }
}

# Direct access to the espn-mcp sidecar for dev testing, bypassing litellm.
# Selects the litellm pod and targets the sidecar's 8080 port by name.
resource "kubernetes_service_v1" "litellm_espn_mcp" {
  depends_on = [kubernetes_deployment_v1.litellm]

  metadata {
    name      = "espn-mcp"
    namespace = local.litellm_ns
    labels    = local.litellm_labels
  }

  spec {
    selector = local.litellm_labels

    port {
      port        = local.litellm_espn_mcp_port
      target_port = "espn-mcp"
      name        = "espn-mcp"
    }
  }
}

resource "kubernetes_manifest" "litellm_espn_mcp_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.litellm_espn_mcp]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "espn-mcp"
      namespace = local.litellm_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.litellm_espn_mcp_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.litellm_espn_mcp.metadata[0].name
          port = local.litellm_espn_mcp_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "litellm_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.litellm]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "litellm"
      namespace = local.litellm_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.litellm_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.litellm.metadata[0].name
          port = local.litellm_port
        }]
      }]
    }
  }
}
