# =============================================================================
# LiteLLM — LLM Gateway + MCP
# =============================================================================
# Migrated from the legacy Podman VM to Kubernetes.

locals {
  litellm_image           = "ghcr.io/berriai/litellm:main-stable"
  litellm_postgres_image  = "docker.io/postgres:latest"
  litellm_finviz_image    = "registry.gitlab.home.shdr.ch/shdrch/finviz-mcp-server/main:latest"
  litellm_coingecko_image = "docker.io/node:22-slim"
  litellm_time_mcp_image  = "docker.io/theo01/mcp-time:latest"
  litellm_host            = "litellm.home.shdr.ch"
  litellm_ns              = kubernetes_namespace_v1.infra.metadata[0].name
  litellm_labels          = { app = "litellm" }
  litellm_port            = 4000
  litellm_finviz_port     = 8000
  litellm_coingecko_port  = 8002
  litellm_time_mcp_port   = 8003
  litellm_postgres_port   = 5432
  litellm_config_yaml     = templatefile("${path.module}/litellm_config.yaml.tftpl", { alphavantage_api_key = var.secrets["alphavantage_api_key"] })
  litellm_database_url    = "postgres://${var.secrets["litellm.database_user"]}:${var.secrets["litellm.database_password"]}@localhost/litellm?sslmode=disable"
  litellm_registry_host   = "registry.gitlab.home.shdr.ch"
  litellm_registry_user   = var.secrets["gitlab.root_email"]
  litellm_registry_pass   = var.secrets["gitlab.root_password"]
}

resource "kubernetes_secret_v1" "litellm_env" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "litellm-env"
    namespace = local.litellm_ns
  }

  data = {
    LITELLM_MASTER_KEY = var.secrets["litellm.master_key"]
    DATABASE_URL       = local.litellm_database_url
    POSTGRES_DB        = "litellm"
    POSTGRES_USER      = var.secrets["litellm.database_user"]
    POSTGRES_PASSWORD  = var.secrets["litellm.database_password"]
    OPENAI_API_KEY     = var.secrets["litellm.openai_api_key"]
    ANTHROPIC_API_KEY  = var.secrets["litellm.anthropic_api_key"]
    OPENROUTER_API_KEY = var.secrets["litellm.openrouter_api_key"]
    OLLAMA_API_KEY     = var.secrets["litellm.ollama_cloud_api_key"]
    FINVIZ_API_KEY     = var.secrets["finviz_api_key"]
    COINGECKO_API_KEY  = var.secrets["coingecko_api_key"]
    LITELLM_CONFIG_SHA = sha256(local.litellm_config_yaml)
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "litellm_config" {
  depends_on = [kubernetes_namespace_v1.infra]

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
  depends_on = [kubernetes_namespace_v1.infra]

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
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

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
}

resource "kubernetes_deployment_v1" "litellm" {
  depends_on = [
    kubernetes_secret_v1.litellm_env,
    kubernetes_secret_v1.litellm_config,
    kubernetes_secret_v1.litellm_gitlab_registry,
    kubernetes_persistent_volume_claim_v1.litellm_postgres_data,
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
          "aether.shdr.ch/config-sha" = sha256(local.litellm_config_yaml)
        }
      }

      spec {
        enable_service_links = false

        image_pull_secrets {
          name = kubernetes_secret_v1.litellm_gitlab_registry.metadata[0].name
        }

        container {
          name  = "postgres"
          image = local.litellm_postgres_image

          port {
            container_port = local.litellm_postgres_port
            name           = "postgres"
          }

          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }

          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d litellm"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }
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
              cpu    = "500m"
              memory = "1Gi"
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
        }

        container {
          name  = "time-mcp-server"
          image = local.litellm_time_mcp_image
          args  = ["--transport", "stream", "--address", "http://0.0.0.0:${local.litellm_time_mcp_port}/mcp"]

          port {
            container_port = local.litellm_time_mcp_port
            name           = "time-mcp"
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.litellm_postgres_data.metadata[0].name
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
