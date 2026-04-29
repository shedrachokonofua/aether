# =============================================================================
# Dawarich — Location History & Timeline
# =============================================================================
# Stack: PostGIS + Redis + app server + Sidekiq background worker.
#
# Data migration (118 MB postgres):
#   dawarich_db_data-default-dawarich-x85obj → k8s PVC
#   dawarich_storage-default-dawarich-x85obj → k8s PVC
#   dawarich_watched-default-dawarich-x85obj (import watch dir) → k8s PVC
#
# Settings fix: was running RAILS_ENV=development with DATABASE_PASSWORD=password.
# Tofu generates a proper password. Must do pg_dump/restore for data continuity.

resource "kubernetes_namespace_v1" "dawarich" {
  depends_on = [helm_release.cilium]
  metadata { name = "dawarich" }
}

resource "random_password" "dawarich_postgres_password" {
  length  = 32
  special = false
}
resource "random_password" "dawarich_secret_key_base" {
  length  = 64
  special = false
}
resource "random_password" "dawarich_otp_encryption_primary_key" {
  length  = 64
  special = false
}
resource "random_password" "dawarich_otp_encryption_deterministic_key" {
  length  = 64
  special = false
}
resource "random_password" "dawarich_otp_encryption_key_derivation_salt" {
  length  = 64
  special = false
}

locals {
  dawarich_image       = "freikin/dawarich:latest"
  dawarich_postgis_image = "postgis/postgis:17-3.5-alpine"
  dawarich_redis_image = "redis:7.4-alpine"

  dawarich_host = "dawarich.home.shdr.ch"

  dawarich_port       = 3000
  dawarich_pg_port    = 5432
  dawarich_redis_port = 6379

  dawarich_ns            = kubernetes_namespace_v1.dawarich.metadata[0].name
  dawarich_labels        = { app = "dawarich" }
  dawarich_sidekiq_labels = { app = "dawarich-sidekiq" }
  dawarich_pg_labels     = { app = "dawarich-postgres" }
  dawarich_redis_labels  = { app = "dawarich-redis" }

  dawarich_db_env = {
    RAILS_ENV         = "production"
    DATABASE_HOST     = "dawarich-postgres.dawarich.svc.cluster.local"
    DATABASE_USERNAME = "postgres"
    DATABASE_PASSWORD = random_password.dawarich_postgres_password.result
    DATABASE_NAME     = "dawarich_production"
    REDIS_URL         = "redis://dawarich-redis.dawarich.svc.cluster.local:${local.dawarich_redis_port}"
    SECRET_KEY_BASE   = random_password.dawarich_secret_key_base.result
    OTP_ENCRYPTION_PRIMARY_KEY = random_password.dawarich_otp_encryption_primary_key.result
    OTP_ENCRYPTION_DETERMINISTIC_KEY = random_password.dawarich_otp_encryption_deterministic_key.result
    OTP_ENCRYPTION_KEY_DERIVATION_SALT = random_password.dawarich_otp_encryption_key_derivation_salt.result
    APPLICATION_HOSTS = "localhost,${local.dawarich_host}"
    TIME_ZONE         = "America/Toronto"
    APPLICATION_PROTOCOL  = "https"
    RAILS_FORCE_SSL       = "0"
    SELF_HOSTED           = "true"
    STORE_GEODATA     = "true"
    MIN_MINUTES_SPENT_IN_CITY = "60"
  }
}

resource "kubernetes_secret_v1" "dawarich_postgres" {
  depends_on = [kubernetes_namespace_v1.dawarich]
  metadata {
    name = "dawarich-postgres"
    namespace = local.dawarich_ns
  }
  data = {
    POSTGRES_PASSWORD = random_password.dawarich_postgres_password.result
    POSTGRES_USER     = "postgres"
    POSTGRES_DB       = "dawarich_production"
  }
  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "dawarich_postgres_data" {
  depends_on = [kubernetes_namespace_v1.dawarich, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "dawarich-postgres-data"
    namespace = local.dawarich_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "10Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_persistent_volume_claim_v1" "dawarich_storage" {
  depends_on = [kubernetes_namespace_v1.dawarich, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "dawarich-storage"
    namespace = local.dawarich_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "dawarich_watched" {
  depends_on = [kubernetes_namespace_v1.dawarich, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "dawarich-watched"
    namespace = local.dawarich_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

# RWX replacements on CephFS so server + sidekiq schedule independently.
resource "kubernetes_persistent_volume_claim_v1" "dawarich_storage_rwx" {
  depends_on = [kubernetes_namespace_v1.dawarich, kubernetes_storage_class_v1.cephfs]
  metadata {
    name = "dawarich-storage-rwx"
    namespace = local.dawarich_ns
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.cephfs.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "dawarich_watched_rwx" {
  depends_on = [kubernetes_namespace_v1.dawarich, kubernetes_storage_class_v1.cephfs]
  metadata {
    name = "dawarich-watched-rwx"
    namespace = local.dawarich_ns
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.cephfs.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

# One-shot rsync from RWO RBD → RWX CephFS for both volumes. Runs on the same
# node as dawarich-server so it can mount the RWO sources alongside the live
# pods (multi-pod RWO is allowed on a single node).
resource "kubernetes_job_v1" "dawarich_rwx_migrate" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.dawarich_storage,
    kubernetes_persistent_volume_claim_v1.dawarich_watched,
    kubernetes_persistent_volume_claim_v1.dawarich_storage_rwx,
    kubernetes_persistent_volume_claim_v1.dawarich_watched_rwx,
  ]

  metadata {
    name      = "dawarich-rwx-migrate"
    namespace = local.dawarich_ns
  }

  spec {
    backoff_limit              = 6
    ttl_seconds_after_finished = 86400

    template {
      metadata {
        labels = {
          app               = "dawarich-rwx-migrate"
          "aether.sh/arm-ok" = "true"
        }
      }

      spec {
        restart_policy = "OnFailure"

        affinity {
          pod_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector { match_labels = local.dawarich_labels }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        container {
          name    = "rsync"
          image   = "alpine:3.20"
          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            apk add --no-cache rsync >/dev/null
            for src in storage watched; do
              echo "rsync $src..."
              rsync -aH --info=progress2 /old-$src/ /new-$src/
            done
            echo "done"
          EOT
          ]

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          volume_mount {
            name       = "old-storage"
            mount_path = "/old-storage"
          }
          volume_mount {
            name       = "new-storage"
            mount_path = "/new-storage"
          }
          volume_mount {
            name       = "old-watched"
            mount_path = "/old-watched"
          }
          volume_mount {
            name       = "new-watched"
            mount_path = "/new-watched"
          }
        }

        volume {
          name = "old-storage"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_storage.metadata[0].name }
        }
        volume {
          name = "new-storage"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_storage_rwx.metadata[0].name }
        }
        volume {
          name = "old-watched"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_watched.metadata[0].name }
        }
        volume {
          name = "new-watched"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_watched_rwx.metadata[0].name }
        }
      }
    }

    completions = 1
  }

  wait_for_completion = true
  timeouts {
    create = "20m"
    update = "20m"
  }
}

# PostGIS (includes postgis extension — required by dawarich)
resource "kubernetes_stateful_set_v1" "dawarich_postgres" {
  depends_on = [kubernetes_secret_v1.dawarich_postgres, kubernetes_persistent_volume_claim_v1.dawarich_postgres_data]
  metadata {
    name      = "dawarich-postgres"
    namespace = local.dawarich_ns
    labels    = local.dawarich_pg_labels
  }
  spec {
    service_name = "dawarich-postgres"
    replicas     = 1
    selector { match_labels = local.dawarich_pg_labels }
    template {
      metadata { labels = local.dawarich_pg_labels }
      spec {
        container {
          name  = "postgis"
          image = local.dawarich_postgis_image
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.dawarich_postgres.metadata[0].name
            }
          }
          env {
            name = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port { container_port = local.dawarich_pg_port }
          volume_mount {
            name = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          readiness_probe {
            exec { command = ["/bin/sh", "-c", "pg_isready -U postgres -d dawarich_production"] }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "2Gi" }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_postgres_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "dawarich_postgres" {
  depends_on = [kubernetes_stateful_set_v1.dawarich_postgres]
  metadata {
    name = "dawarich-postgres"
    namespace = local.dawarich_ns
    labels = local.dawarich_pg_labels
  }
  spec {
    selector = local.dawarich_pg_labels
    port {
      port = local.dawarich_pg_port
      target_port = local.dawarich_pg_port
    }
    type = "ClusterIP"
  }
}

# Redis
resource "kubernetes_deployment_v1" "dawarich_redis" {
  depends_on = [kubernetes_namespace_v1.dawarich]
  metadata {
    name      = "dawarich-redis"
    namespace = local.dawarich_ns
    labels    = local.dawarich_redis_labels
  }
  spec {
    replicas = 1
    selector { match_labels = local.dawarich_redis_labels }
    template {
      metadata { labels = local.dawarich_redis_labels }
      spec {
        enable_service_links = false
        container {
          name    = "redis"
          image   = local.dawarich_redis_image
          command = ["redis-server", "--save", "", "--appendonly", "no"]
          port { container_port = local.dawarich_redis_port }
          resources {
            requests = { cpu = "30m", memory = "32Mi" }
            limits   = { cpu = "300m", memory = "256Mi" }
          }
          readiness_probe {
            exec { command = ["redis-cli", "ping"] }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "dawarich_redis" {
  metadata {
    name = "dawarich-redis"
    namespace = local.dawarich_ns
    labels = local.dawarich_redis_labels
  }
  spec {
    selector = local.dawarich_redis_labels
    port {
      port = local.dawarich_redis_port
      target_port = local.dawarich_redis_port
    }
  }
}

# App Server
resource "kubernetes_deployment_v1" "dawarich" {
  depends_on = [
    kubernetes_service_v1.dawarich_postgres,
    kubernetes_service_v1.dawarich_redis,
    kubernetes_persistent_volume_claim_v1.dawarich_storage_rwx,
    kubernetes_persistent_volume_claim_v1.dawarich_watched_rwx,
    kubernetes_job_v1.dawarich_rwx_migrate,
  ]
  metadata {
    name      = "dawarich"
    namespace = local.dawarich_ns
    labels    = local.dawarich_labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = local.dawarich_labels }
    template {
      metadata { labels = local.dawarich_labels }
      spec {
        enable_service_links = false
        container {
          name       = "dawarich"
          image      = local.dawarich_image
          command = ["web-entrypoint.sh"]
          args = ["bin/rails", "server", "-p", "3000", "-b", "::"]

          dynamic "env" {
            for_each = local.dawarich_db_env
            content {
              name  = env.key
              value = env.value
            }
          }

          port {
            container_port = local.dawarich_port
            name = "http"
          }

          volume_mount {
            name = "storage"
            mount_path = "/var/app/storage"
          }
          volume_mount {
            name = "watched"
            mount_path = "/var/app/tmp/imports/watched"
          }

          resources {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "2", memory = "4Gi" }
          }

          readiness_probe {
            tcp_socket {
              port = local.dawarich_port
            }
            initial_delay_seconds = 60
            period_seconds        = 15
          }
        }

        volume {
          name = "storage"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_storage_rwx.metadata[0].name }
        }
        volume {
          name = "watched"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_watched_rwx.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "dawarich" {
  metadata {
    name = "dawarich"
    namespace = local.dawarich_ns
    labels = local.dawarich_labels
  }
  spec {
    selector = local.dawarich_labels
    port {
      port = local.dawarich_port
      target_port = local.dawarich_port
      name = "http"
    }
  }
}

# Sidekiq background worker
resource "kubernetes_deployment_v1" "dawarich_sidekiq" {
  depends_on = [kubernetes_deployment_v1.dawarich]
  metadata {
    name      = "dawarich-sidekiq"
    namespace = local.dawarich_ns
    labels    = local.dawarich_sidekiq_labels
  }
  spec {
    replicas = 1
    selector { match_labels = local.dawarich_sidekiq_labels }
    template {
      metadata { labels = local.dawarich_sidekiq_labels }
      spec {
        enable_service_links = false
        container {
          name    = "sidekiq"
          image   = local.dawarich_image
          command = ["sidekiq-entrypoint.sh"]
          args = ["sidekiq"]

          dynamic "env" {
            for_each = local.dawarich_db_env
            content {
              name  = env.key
              value = env.value
            }
          }

          env {
            name  = "BACKGROUND_PROCESSING_CONCURRENCY"
            value = "5"
          }

          volume_mount {
            name = "storage"
            mount_path = "/var/app/storage"
          }
          volume_mount {
            name = "watched"
            mount_path = "/var/app/tmp/imports/watched"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "2Gi" }
          }
        }
        volume {
          name = "storage"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_storage_rwx.metadata[0].name }
        }
        volume {
          name = "watched"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.dawarich_watched_rwx.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_manifest" "dawarich_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.dawarich]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "dawarich", namespace = local.dawarich_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.dawarich_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" },
              { name = "X-Forwarded-Ssl", value = "On" },
            ]
          }
        }]
        backendRefs = [{ name = "dawarich", port = local.dawarich_port }]
      }]
    }
  }
}
