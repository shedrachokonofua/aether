# =============================================================================
# Firecrawl - Web Crawling + MCP
# =============================================================================
# Migrated from the legacy Podman VM to Kubernetes.

locals {
  firecrawl_image            = "ghcr.io/firecrawl/firecrawl:latest"
  firecrawl_playwright_image = "ghcr.io/firecrawl/playwright-service:latest"
  firecrawl_postgres_image   = "ghcr.io/firecrawl/nuq-postgres:latest"
  firecrawl_redis_image      = "docker.io/redis:alpine"
  firecrawl_rabbitmq_image   = "docker.io/rabbitmq:3-management"
  firecrawl_mcp_image        = "docker.io/node:22-alpine"

  firecrawl_host     = "firecrawl.apps.home.shdr.ch"
  firecrawl_mcp_host = "firecrawl-mcp.apps.home.shdr.ch"
  firecrawl_ns       = kubernetes_namespace_v1.infra.metadata[0].name
  firecrawl_labels   = { app = "firecrawl" }

  firecrawl_api_port        = 3002
  firecrawl_mcp_port        = 3007
  firecrawl_playwright_port = 3000
}

# =============================================================================
# Secrets + Storage
# =============================================================================

resource "kubernetes_secret_v1" "firecrawl_env" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "firecrawl-env"
    namespace = local.firecrawl_ns
  }

  data = {
    DATABASE_PASSWORD = var.secrets["firecrawl.database_password"]
    BULL_AUTH_KEY     = var.secrets["firecrawl.bull_auth_key"]
    TEST_API_KEY      = var.secrets["firecrawl.api_key"]
    FIRECRAWL_API_KEY = var.secrets["firecrawl.api_key"]
    OPENAI_API_KEY    = var.secrets["litellm.virtual_keys.firecrawl"]
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "firecrawl_redis_data" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "firecrawl-redis-data"
    namespace = local.firecrawl_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "2Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "firecrawl_postgres_data" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "firecrawl-postgres-data"
    namespace = local.firecrawl_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "10Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "firecrawl" {
  depends_on = [
    kubernetes_secret_v1.firecrawl_env,
    kubernetes_persistent_volume_claim_v1.firecrawl_redis_data,
    kubernetes_persistent_volume_claim_v1.firecrawl_postgres_data,
    kubernetes_service_v1.searxng,
  ]

  metadata {
    name      = "firecrawl"
    namespace = local.firecrawl_ns
    labels    = local.firecrawl_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.firecrawl_labels
    }

    template {
      metadata {
        labels = local.firecrawl_labels
      }

      spec {
        enable_service_links = false

        container {
          name    = "redis"
          image   = local.firecrawl_redis_image
          command = ["redis-server", "--bind", "0.0.0.0"]

          port {
            container_port = 6379
            name           = "redis"
          }

          volume_mount {
            name       = "redis-data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        container {
          name  = "rabbitmq"
          image = local.firecrawl_rabbitmq_image

          port {
            container_port = 5672
            name           = "amqp"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        container {
          name  = "postgres"
          image = local.firecrawl_postgres_image

          port {
            container_port = 5432
            name           = "postgres"
          }

          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "DATABASE_PASSWORD"
              }
            }
          }

          env {
            name  = "POSTGRES_DB"
            value = "postgres"
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
        }

        container {
          name  = "playwright"
          image = local.firecrawl_playwright_image

          port {
            container_port = local.firecrawl_playwright_port
            name           = "playwright"
          }

          env {
            name  = "PORT"
            value = tostring(local.firecrawl_playwright_port)
          }

          env {
            name  = "MAX_CONCURRENT_PAGES"
            value = "10"
          }

          env {
            name  = "PROXY_SERVER"
            value = "socks5://${var.rotating_proxy_addr}"
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
        }

        container {
          name    = "api"
          image   = local.firecrawl_image
          command = ["node", "dist/src/harness.js", "--start-docker"]

          port {
            container_port = local.firecrawl_api_port
            name           = "api"
          }

          env {
            name  = "HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "ENV"
            value = "local"
          }

          env {
            name  = "PORT"
            value = tostring(local.firecrawl_api_port)
          }

          env {
            name  = "EXTRACT_WORKER_PORT"
            value = "3004"
          }

          env {
            name  = "WORKER_PORT"
            value = "3005"
          }

          env {
            name  = "NUQ_WORKER_START_PORT"
            value = "3100"
          }

          env {
            name  = "NUM_WORKERS_PER_QUEUE"
            value = "8"
          }

          env {
            name = "DATABASE_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "DATABASE_PASSWORD"
              }
            }
          }

          env {
            name = "BULL_AUTH_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "BULL_AUTH_KEY"
              }
            }
          }

          env {
            name = "TEST_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "TEST_API_KEY"
              }
            }
          }

          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }

          env {
            name  = "REDIS_URL"
            value = "redis://localhost:6379"
          }

          env {
            name  = "REDIS_RATE_LIMIT_URL"
            value = "redis://localhost:6379"
          }

          env {
            name  = "PLAYWRIGHT_MICROSERVICE_URL"
            value = "http://localhost:${local.firecrawl_playwright_port}/scrape"
          }

          env {
            name  = "NUQ_DATABASE_URL"
            value = "postgres://postgres:$(DATABASE_PASSWORD)@localhost:5432/postgres"
          }

          env {
            name  = "NUQ_RABBITMQ_URL"
            value = "amqp://localhost:5672"
          }

          env {
            name  = "USE_DB_AUTHENTICATION"
            value = "false"
          }

          env {
            name  = "OPENAI_BASE_URL"
            value = "https://litellm.home.shdr.ch/v1"
          }

          env {
            name  = "MODEL_NAME"
            value = "aether/qwen3:8b"
          }

          env {
            name  = "MODEL_EMBEDDING_NAME"
            value = "aether/qwen3-embedding:4b"
          }

          env {
            name  = "LOGGING_LEVEL"
            value = "debug"
          }

          env {
            name  = "SEARXNG_ENDPOINT"
            value = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.firecrawl_ns}.svc.cluster.local:${local.searxng_port}"
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

          readiness_probe {
            tcp_socket {
              port = local.firecrawl_api_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        container {
          name    = "mcp"
          image   = local.firecrawl_mcp_image
          command = ["npx", "-y", "firecrawl-mcp"]

          port {
            container_port = local.firecrawl_mcp_port
            name           = "mcp"
          }

          env {
            name  = "PORT"
            value = tostring(local.firecrawl_mcp_port)
          }

          env {
            name  = "HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "HTTP_STREAMABLE_SERVER"
            value = "true"
          }

          env {
            name = "FIRECRAWL_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "FIRECRAWL_API_KEY"
              }
            }
          }

          env {
            name  = "FIRECRAWL_API_URL"
            value = "https://firecrawl.home.shdr.ch"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "redis-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.firecrawl_redis_data.metadata[0].name
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.firecrawl_postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "firecrawl" {
  metadata {
    name      = "firecrawl"
    namespace = local.firecrawl_ns
    labels    = local.firecrawl_labels
  }

  spec {
    selector = local.firecrawl_labels

    port {
      port        = local.firecrawl_api_port
      target_port = local.firecrawl_api_port
      name        = "api"
    }

    port {
      port        = local.firecrawl_mcp_port
      target_port = local.firecrawl_mcp_port
      name        = "mcp"
    }
  }
}

# =============================================================================
# HTTPRoutes - Gateway API
# =============================================================================

resource "kubernetes_manifest" "firecrawl_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.firecrawl]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "firecrawl"
      namespace = local.firecrawl_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.firecrawl_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.firecrawl.metadata[0].name
          port = local.firecrawl_api_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "firecrawl_mcp_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.firecrawl]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "firecrawl-mcp"
      namespace = local.firecrawl_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.firecrawl_mcp_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.firecrawl.metadata[0].name
          port = local.firecrawl_mcp_port
        }]
      }]
    }
  }
}
