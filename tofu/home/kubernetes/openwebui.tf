# =============================================================================
# OpenWebUI + MCPO
# =============================================================================
# Migrated from ai_tool_stack podman quadlets to Kubernetes.

locals {
  openwebui_namespace = "infra"
  openwebui_host      = "openwebui.apps.home.shdr.ch"
  openwebui_image     = "ghcr.io/open-webui/open-webui:latest"
  mcpo_image          = "ghcr.io/open-webui/mcpo:main"
  postgres_image      = "pgvector/pgvector:pg16"
  postgres_service    = "openwebui-postgres"
  postgres_db         = "openwebui"
  postgres_user       = "openwebui"
  postgres_port       = 5432
  postgres_url        = "postgresql://${local.postgres_user}:${random_password.openwebui_postgres_password.result}@${local.postgres_service}.${local.openwebui_namespace}.svc.cluster.local:${local.postgres_port}/${local.postgres_db}"

  openwebui_tool_server_connections = jsonencode([{
    type      = "openapi"
    url       = "http://127.0.0.1:8001/litellm"
    spec_type = "url"
    spec      = ""
    path      = "openapi.json"
    auth_type = "bearer"
    key       = var.secrets["openwebui.mcpo_api_key"]
    config = {
      enable = true
      access_control = {
        read  = { group_ids = [], user_ids = [] }
        write = { group_ids = [], user_ids = [] }
      }
    }
    info = {
      id          = "litellm"
      name        = "LiteLLM"
      description = "LiteLLM"
    }
  }])

  mcpo_config = jsonencode({
    mcpServers = {
      litellm = {
        type = "streamable-http"
        url  = var.litellm_mcp_url
        headers = {
          "x-litellm-api-key" = "Bearer ${var.secrets["litellm.virtual_keys.openwebui"]}"
        }
      }
    }
  })
}

resource "kubernetes_namespace_v1" "infra" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.openwebui_namespace
  }
}

resource "kubernetes_secret_v1" "openwebui_env" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "openwebui-env"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
  }

  data = {
    WEBUI_SECRET_KEY        = var.secrets["openwebui.secret_key"]
    OPENAI_API_KEY          = var.secrets["litellm.virtual_keys.openwebui"]
    RAG_OPENAI_API_KEY      = var.secrets["litellm.virtual_keys.openwebui"]
    RERANKER_API_KEY        = var.secrets["litellm.virtual_keys.openwebui"]
    DATABASE_URL            = local.postgres_url
    PGVECTOR_DB_URL         = local.postgres_url
    OAUTH_CLIENT_SECRET     = var.openwebui_oauth_client_secret
    MCPO_API_KEY            = var.secrets["openwebui.mcpo_api_key"]
    TOOL_SERVER_CONNECTIONS = local.openwebui_tool_server_connections
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "openwebui_mcpo_config" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "openwebui-mcpo-config"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
  }

  data = {
    "config.json" = local.mcpo_config
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "openwebui_data" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "openwebui-data"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
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

resource "random_password" "openwebui_postgres_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "openwebui_postgres" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "openwebui-postgres"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
  }

  data = {
    POSTGRES_DB       = local.postgres_db
    POSTGRES_USER     = local.postgres_user
    POSTGRES_PASSWORD = random_password.openwebui_postgres_password.result
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "openwebui_postgres_data" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "openwebui-postgres-data"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
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

resource "kubernetes_stateful_set_v1" "openwebui_postgres" {
  depends_on = [kubernetes_secret_v1.openwebui_postgres, kubernetes_persistent_volume_claim_v1.openwebui_postgres_data]

  metadata {
    name      = local.postgres_service
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
    labels = {
      app = local.postgres_service
    }
  }

  spec {
    service_name = local.postgres_service
    replicas     = 1

    selector {
      match_labels = {
        app = local.postgres_service
      }
    }

    template {
      metadata {
        labels = {
          app = local.postgres_service
        }
      }

      spec {
        container {
          name  = "postgres"
          image = local.postgres_image

          port {
            container_port = local.postgres_port
          }

          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_postgres.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }

          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_postgres.metadata[0].name
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
              command = ["/bin/sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            exec {
              command = ["/bin/sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.openwebui_postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "openwebui_postgres" {
  depends_on = [kubernetes_stateful_set_v1.openwebui_postgres]

  metadata {
    name      = local.postgres_service
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
    labels = {
      app = local.postgres_service
    }
  }

  spec {
    selector = {
      app = local.postgres_service
    }

    port {
      port        = local.postgres_port
      target_port = local.postgres_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_deployment_v1" "openwebui" {
  depends_on = [
    kubernetes_secret_v1.openwebui_env,
    kubernetes_secret_v1.openwebui_mcpo_config,
    kubernetes_persistent_volume_claim_v1.openwebui_data,
    kubernetes_service_v1.openwebui_postgres
  ]

  metadata {
    name      = "openwebui"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
    labels = {
      app = "openwebui"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "openwebui"
      }
    }

    template {
      metadata {
        labels = {
          app = "openwebui"
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "openwebui"
          image = local.openwebui_image

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            run_as_non_root = true
          }

          port {
            container_port = 8080
          }

          env {
            name  = "ENABLE_PERSISTENT_CONFIG"
            value = "false"
          }
          env {
            name = "WEBUI_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "WEBUI_SECRET_KEY"
              }
            }
          }
          env {
            name  = "OPENAI_API_BASE_URL"
            value = "https://litellm.home.shdr.ch/v1"
          }
          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }
          env {
            name  = "ENABLE_OLLAMA_API"
            value = "false"
          }
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name  = "VECTOR_DB"
            value = "pgvector"
          }
          env {
            name = "PGVECTOR_DB_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "PGVECTOR_DB_URL"
              }
            }
          }
          env {
            name  = "PGVECTOR_CREATE_EXTENSION"
            value = "true"
          }
          env {
            name  = "ENABLE_WEB_SEARCH"
            value = "true"
          }
          env {
            name  = "WEB_SEARCH_RESULT_COUNT"
            value = "10"
          }
          env {
            name  = "WEB_SEARCH_ENGINE"
            value = "searxng"
          }
          env {
            name  = "SEARXNG_QUERY_URL"
            value = "https://searxng.home.shdr.ch/search?format=json&q=<query>"
          }
          env {
            name  = "CONTENT_EXTRACTION_ENGINE"
            value = "docling"
          }
          env {
            name  = "DOCLING_SERVER_URL"
            value = "https://docling.home.shdr.ch"
          }
          env {
            name  = "RAG_EMBEDDING_ENGINE"
            value = "openai"
          }
          env {
            name  = "RAG_OPENAI_API_BASE_URL"
            value = "https://litellm.home.shdr.ch/v1"
          }
          env {
            name = "RAG_OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "RAG_OPENAI_API_KEY"
              }
            }
          }
          env {
            name  = "RAG_EMBEDDING_MODEL"
            value = "aether/qwen3-embedding:4b"
          }
          env {
            name  = "ENABLE_RAG_HYBRID_SEARCH"
            value = "true"
          }
          env {
            name  = "ENABLE_RAG_HYBRID_SEARCH_ENRICHED_TEXTS"
            value = "true"
          }
          env {
            name  = "RAG_RERANKING_MODEL"
            value = "aether/bge-reranker-large"
          }
          env {
            name  = "RAG_RERANKING_ENGINE"
            value = "external"
          }
          env {
            name  = "RAG_EXTERNAL_RERANKER_URL"
            value = "https://litellm.home.shdr.ch/rerank"
          }
          env {
            name = "RAG_EXTERNAL_RERANKER_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "RERANKER_API_KEY"
              }
            }
          }
          env {
            name  = "RAG_TOP_K"
            value = "10"
          }
          env {
            name  = "RAG_TOP_K_RERANKER"
            value = "10"
          }
          env {
            name  = "RAG_RELEVANCE_THRESHOLD"
            value = "0.0"
          }
          env {
            name  = "RAG_ALLOWED_FILE_EXTENSIONS"
            value = "pdf,docx,txt,pptx,csv,xlsx,xls"
          }
          env {
            name  = "CODE_EXECUTION_ENGINE"
            value = "jupyter"
          }
          env {
            name  = "CODE_EXECUTION_JUPYTER_URL"
            value = "https://jupyter.home.shdr.ch"
          }
          env {
            name  = "CODE_INTERPRETER_ENGINE"
            value = "jupyter"
          }
          env {
            name  = "CODE_INTERPRETER_JUPYTER_URL"
            value = "https://jupyter.home.shdr.ch"
          }
          env {
            name = "TOOL_SERVER_CONNECTIONS"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "TOOL_SERVER_CONNECTIONS"
              }
            }
          }
          env {
            name  = "WEBUI_URL"
            value = "https://ai.shdr.ch"
          }
          env {
            name  = "FORWARDED_ALLOW_IPS"
            value = "*"
          }
          env {
            name  = "ENABLE_LOGIN_FORM"
            value = "false"
          }
          env {
            name  = "ENABLE_OAUTH_SIGNUP"
            value = "true"
          }
          env {
            name  = "OAUTH_PROVIDER_NAME"
            value = "Aether"
          }
          env {
            name  = "OAUTH_CLIENT_ID"
            value = "openwebui"
          }
          env {
            name = "OAUTH_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "OAUTH_CLIENT_SECRET"
              }
            }
          }
          env {
            name  = "OPENID_PROVIDER_URL"
            value = "https://auth.shdr.ch/realms/aether/.well-known/openid-configuration"
          }
          env {
            name  = "OPENID_REDIRECT_URI"
            value = "https://ai.shdr.ch/oauth/oidc/callback"
          }
          env {
            name  = "OAUTH_SCOPES"
            value = "openid email profile roles"
          }
          env {
            name  = "ENABLE_OAUTH_ROLE_MANAGEMENT"
            value = "true"
          }
          env {
            name  = "OAUTH_ROLES_CLAIM"
            value = "roles"
          }
          env {
            name  = "OAUTH_ALLOWED_ROLES"
            value = "admin,openwebui-user"
          }
          env {
            name  = "OAUTH_ADMIN_ROLES"
            value = "admin"
          }

          # Performance tuning for small multi-user deployments.
          env {
            name  = "ENABLE_BASE_MODELS_CACHE"
            value = "true"
          }
          env {
            name  = "MODELS_CACHE_TTL"
            value = "300"
          }
          env {
            name  = "ENABLE_QUERIES_CACHE"
            value = "true"
          }
          env {
            name  = "RAG_SYSTEM_CONTEXT"
            value = "true"
          }
          env {
            name  = "ENABLE_REALTIME_CHAT_SAVE"
            value = "false"
          }
          env {
            name  = "DATABASE_ENABLE_SESSION_SHARING"
            value = "true"
          }
          env {
            name  = "CHAT_RESPONSE_STREAM_DELTA_CHUNK_SIZE"
            value = "7"
          }
          env {
            name  = "THREAD_POOL_SIZE"
            value = "200"
          }
          env {
            name  = "AIOHTTP_CLIENT_TIMEOUT"
            value = "1800"
          }
          env {
            name  = "AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST"
            value = "15"
          }
          env {
            name  = "AIOHTTP_CLIENT_TIMEOUT_OPENAI_MODEL_LIST"
            value = "15"
          }

          readiness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 45
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "750m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "4000m"
              memory = "8Gi"
            }
          }

          volume_mount {
            name       = "openwebui-data"
            mount_path = "/app/backend/data"
          }
        }

        container {
          name  = "mcpo"
          image = local.mcpo_image

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            run_as_non_root = true
          }

          command = ["/bin/sh", "-c"]
          args = [
            "mcpo --config /config/config.json --port 8001 --api-key \"$MCPO_API_KEY\""
          ]

          env {
            name = "MCPO_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.openwebui_env.metadata[0].name
                key  = "MCPO_API_KEY"
              }
            }
          }

          port {
            container_port = 8001
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "mcpo-config"
            mount_path = "/config/config.json"
            sub_path   = "config.json"
            read_only  = true
          }
        }

        volume {
          name = "openwebui-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.openwebui_data.metadata[0].name
          }
        }

        volume {
          name = "mcpo-config"
          secret {
            secret_name = kubernetes_secret_v1.openwebui_mcpo_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "openwebui" {
  depends_on = [kubernetes_deployment_v1.openwebui]

  metadata {
    name      = "openwebui"
    namespace = kubernetes_namespace_v1.infra.metadata[0].name
    labels = {
      app = "openwebui"
    }
  }

  spec {
    selector = {
      app = "openwebui"
    }

    port {
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_manifest" "openwebui_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.openwebui]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "openwebui"
      namespace = kubernetes_namespace_v1.infra.metadata[0].name
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.openwebui_host]
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
            set = [
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.openwebui.metadata[0].name
          port = 8080
        }]
      }]
    }
  }
}
