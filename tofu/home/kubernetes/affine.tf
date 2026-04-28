# =============================================================================
# AFFiNE — Collaborative Workspace (notes, whiteboards, kanban)
# =============================================================================
# Stack: affine server + migration job + PGVector postgres + Redis + Manticore indexer.
#
# Data migration:
#   affine_db-default-affine-ghfpkn → k8s PVC (89 MB postgres)
#   affine_uploads-default-affine-ghfpkn → k8s PVC
#   affine_indexer-default-affine-ghfpkn → k8s PVC (Manticore data)
#   ../files/config.json → read via RBD snapshot and store in k8s Secret

resource "kubernetes_namespace_v1" "affine" {
  depends_on = [helm_release.cilium]
  metadata { name = "affine" }
}

resource "random_password" "affine_db_password" {
  length  = 32
  special = false
}

locals {
  affine_version  = "0.26.3"
  affine_image    = "ghcr.io/toeverything/affine:${local.affine_version}"
  affine_pg_image = "pgvector/pgvector:pg16"
  affine_redis_image   = "redis:latest"
  affine_manticore_image = "manticoresearch/manticore:10.1.0"

  affine_gateway_host = "affine.apps.home.shdr.ch"
  affine_host         = "affine.home.shdr.ch"
  affine_port         = 3010

  affine_pg_port       = 5432
  affine_redis_port    = 6379
  affine_manticore_port = 9308

  affine_ns              = kubernetes_namespace_v1.affine.metadata[0].name
  affine_labels          = { app = "affine" }
  affine_pg_labels       = { app = "affine-postgres" }
  affine_redis_labels    = { app = "affine-redis" }
  affine_manticore_labels = { app = "affine-manticore" }
}

resource "kubernetes_secret_v1" "affine_postgres" {
  depends_on = [kubernetes_namespace_v1.affine]
  metadata {
    name = "affine-postgres"
    namespace = local.affine_ns
  }
  data = {
    POSTGRES_USER     = "affine"
    POSTGRES_PASSWORD = random_password.affine_db_password.result
    POSTGRES_DB       = "affine"
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "affine_config" {
  depends_on = [kubernetes_namespace_v1.affine]
  metadata {
    name      = "affine-config"
    namespace = local.affine_ns
  }
  data = {
    "config.json" = jsonencode({
      "$schema" = "https://github.com/toeverything/affine/releases/latest/download/config.schema.json"
      auth = {
        requireEmailVerification = false
      }
      oauth = {
        providers = {
          oidc = {
            issuer       = var.oidc_issuer_url
            clientId     = "affine"
            clientSecret = var.affine_oauth_client_secret
            args = {
              scope = "openid profile email"
            }
          }
        }
      }
      copilot = {
        enabled = true
        "providers.openai" = {
          apiKey      = var.secrets["litellm.virtual_keys.affine"]
          baseURL     = "https://litellm.home.shdr.ch/v1"
          oldApiStyle = true
        }
        scenarios = {
          override_enabled = true
          scenarios = {
            chat                    = "aether/gemma-4-26b-a4b"
            coding                  = "aether/qwen3.6-35b-a3b:code"
            complex_text_generation = "aether/gemma-4-26b-a4b"
            polish_and_summarize    = "aether/qwen3.5-9b"
            quick_decision_making   = "aether/qwen3.5-9b"
            quick_text_generation   = "aether/gemma-4-26b-a4b"
            rerank                  = "aether/bge-reranker-v2-m3"
            embedding               = "aether/qwen3-embedding:4b"
            audio_transcribing      = "aether/whisper-large-v3"
            image                   = "gpt-image-1"
          }
        }
      }
    })
  }
  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "affine_postgres_data" {
  depends_on = [kubernetes_namespace_v1.affine, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "affine-postgres-data"
    namespace = local.affine_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "10Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_persistent_volume_claim_v1" "affine_uploads" {
  depends_on = [kubernetes_namespace_v1.affine, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "affine-uploads"
    namespace = local.affine_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "10Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_persistent_volume_claim_v1" "affine_indexer" {
  depends_on = [kubernetes_namespace_v1.affine, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "affine-indexer"
    namespace = local.affine_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

# PGVector Postgres
resource "kubernetes_stateful_set_v1" "affine_postgres" {
  depends_on = [kubernetes_secret_v1.affine_postgres, kubernetes_persistent_volume_claim_v1.affine_postgres_data]
  metadata {
    name      = "affine-postgres"
    namespace = local.affine_ns
    labels    = local.affine_pg_labels
  }
  spec {
    service_name = "affine-postgres"
    replicas     = 1
    selector { match_labels = local.affine_pg_labels }
    template {
      metadata { labels = local.affine_pg_labels }
      spec {
        container {
          name  = "postgres"
          image = local.affine_pg_image
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.affine_postgres.metadata[0].name
            }
          }
          env {
            name = "POSTGRES_INITDB_ARGS"
            value = "--data-checksums"
          }
          env {
            name = "POSTGRES_HOST_AUTH_METHOD"
            value = "trust"
          }
          env {
            name = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port { container_port = local.affine_pg_port }
          volume_mount {
            name = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          readiness_probe {
            exec { command = ["/bin/sh", "-c", "pg_isready -U affine -d affine"] }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.affine_postgres_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "affine_postgres" {
  depends_on = [kubernetes_stateful_set_v1.affine_postgres]
  metadata {
    name = "affine-postgres"
    namespace = local.affine_ns
    labels = local.affine_pg_labels
  }
  spec {
    selector = local.affine_pg_labels
    port {
      port = local.affine_pg_port
      target_port = local.affine_pg_port
    }
    type = "ClusterIP"
  }
}

# Redis
resource "kubernetes_deployment_v1" "affine_redis" {
  depends_on = [kubernetes_namespace_v1.affine]
  metadata {
    name      = "affine-redis"
    namespace = local.affine_ns
    labels    = local.affine_redis_labels
  }
  spec {
    replicas = 1
    selector { match_labels = local.affine_redis_labels }
    template {
      metadata { labels = local.affine_redis_labels }
      spec {
        enable_service_links = false
        container {
          name  = "redis"
          image = local.affine_redis_image
          port { container_port = local.affine_redis_port }
          readiness_probe {
            exec { command = ["redis-cli", "ping"] }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          resources {
            requests = { cpu = "30m", memory = "32Mi" }
            limits   = { cpu = "300m", memory = "256Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "affine_redis" {
  metadata {
    name = "affine-redis"
    namespace = local.affine_ns
    labels = local.affine_redis_labels
  }
  spec {
    selector = local.affine_redis_labels
    port {
      port = local.affine_redis_port
      target_port = local.affine_redis_port
    }
  }
}

# Manticore Search Indexer
resource "kubernetes_deployment_v1" "affine_manticore" {
  depends_on = [kubernetes_persistent_volume_claim_v1.affine_indexer]
  metadata {
    name      = "affine-manticore"
    namespace = local.affine_ns
    labels    = local.affine_manticore_labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = local.affine_manticore_labels }
    template {
      metadata { labels = local.affine_manticore_labels }
      spec {
        enable_service_links = false
        container {
          name  = "manticore"
          image = local.affine_manticore_image
          port { container_port = local.affine_manticore_port }
          volume_mount {
            name = "data"
            mount_path = "/var/lib/manticore"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = local.affine_manticore_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.affine_indexer.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "affine_manticore" {
  metadata {
    name = "affine-manticore"
    namespace = local.affine_ns
    labels = local.affine_manticore_labels
  }
  spec {
    selector = local.affine_manticore_labels
    port {
      port = local.affine_manticore_port
      target_port = local.affine_manticore_port
    }
  }
}

# Migration job — runs DB migrations before server starts; idempotent
resource "kubernetes_job_v1" "affine_migration" {
  depends_on = [
    kubernetes_service_v1.affine_postgres,
    kubernetes_service_v1.affine_redis,
  ]
  metadata {
    name = "affine-migration"
    namespace = local.affine_ns
  }
  spec {
    backoff_limit              = 4
    ttl_seconds_after_finished = 86400
    template {
      metadata { labels = { app = "affine-migration" } }
      spec {
        restart_policy = "OnFailure"
        container {
          name    = "migration"
          image   = local.affine_image
          command = ["sh", "-c", "node ./scripts/self-host-predeploy.js"]
          env {
            name = "REDIS_SERVER_HOST"
            value = "affine-redis.${local.affine_ns}.svc.cluster.local"
          }
          env {
            name = "DATABASE_URL"
            value = "postgresql://affine:${random_password.affine_db_password.result}@affine-postgres.${local.affine_ns}.svc.cluster.local:${local.affine_pg_port}/affine"
          }
          env {
            name = "AFFINE_INDEXER_ENABLED"
            value = "true"
          }
          env {
            name = "AFFINE_INDEXER_SEARCH_ENDPOINT"
            value = "http://affine-manticore.${local.affine_ns}.svc.cluster.local:${local.affine_manticore_port}"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
        }
      }
    }
  }
  lifecycle { ignore_changes = [spec[0].template] }
}

# AFFiNE Server
resource "kubernetes_deployment_v1" "affine" {
  depends_on = [
    kubernetes_job_v1.affine_migration,
    kubernetes_service_v1.affine_manticore,
    kubernetes_persistent_volume_claim_v1.affine_uploads,
    kubernetes_secret_v1.affine_config,
  ]
  metadata {
    name      = "affine"
    namespace = local.affine_ns
    labels    = local.affine_labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = local.affine_labels }
    template {
      metadata { labels = local.affine_labels }
      spec {
        enable_service_links = false
        container {
          name  = "affine"
          image = local.affine_image

          env {
            name = "selfhosted"
            value = "true"
          }
          env {
            name = "REDIS_SERVER_HOST"
            value = "affine-redis.${local.affine_ns}.svc.cluster.local"
          }
          env {
            name = "DATABASE_URL"
            value = "postgresql://affine:${random_password.affine_db_password.result}@affine-postgres.${local.affine_ns}.svc.cluster.local:${local.affine_pg_port}/affine"
          }
          env {
            name = "AFFINE_INDEXER_ENABLED"
            value = "true"
          }
          env {
            name = "AFFINE_INDEXER_SEARCH_ENDPOINT"
            value = "http://affine-manticore.${local.affine_ns}.svc.cluster.local:${local.affine_manticore_port}"
          }
          env {
            name = "AFFINE_SERVER_EXTERNAL_URL"
            value = "https://${local.affine_host}"
          }
          env {
            name = "PORT"
            value = tostring(local.affine_port)
          }

          port {
            container_port = local.affine_port
            name = "http"
          }

          volume_mount {
            name = "uploads"
            mount_path = "/root/.affine/storage"
          }

          volume_mount {
            name       = "config"
            mount_path = "/root/.affine/config/config.json"
            sub_path   = "config.json"
            read_only  = true
          }

          resources {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "2", memory = "4Gi" }
          }

          readiness_probe {
            http_get {
              path = "/info"
              port = local.affine_port
            }
            initial_delay_seconds = 30
            period_seconds        = 15
          }
        }
        volume {
          name = "uploads"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.affine_uploads.metadata[0].name }
        }
        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.affine_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "affine" {
  metadata {
    name = "affine"
    namespace = local.affine_ns
    labels = local.affine_labels
  }
  spec {
    selector = local.affine_labels
    port {
      port = local.affine_port
      target_port = local.affine_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "affine_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.affine]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "affine", namespace = local.affine_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.affine_gateway_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "affine", port = local.affine_port }]
      }]
    }
  }
}
