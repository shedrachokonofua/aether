# =============================================================================
# Immich — Self-hosted Photo & Video Library
# =============================================================================
# Stack:
#   - immich-server   (API + web UI)
#   - immich-ml       (CLIP smart-search + InsightFace face recognition, GPU)
#   - postgres        (Immich's official image with VectorChord + pgvecto.rs)
#   - redis           (job queue)
# Storage:
#   - library  -> NFS (/mnt/hdd/data/immich on smith)
#   - postgres -> ceph-rbd
#   - ml model cache -> ceph-rbd (pod floats across GPU nodes)

locals {
  immich_namespace = "immich"
  immich_host      = "immich.apps.home.shdr.ch"

  immich_server_image   = "ghcr.io/immich-app/immich-server:release"
  immich_ml_image       = "ghcr.io/immich-app/immich-machine-learning:release-cuda"
  immich_postgres_image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
  immich_redis_image    = "redis:6.2-alpine"

  immich_server_port   = 2283
  immich_ml_port       = 3003
  immich_postgres_port = 5432
  immich_redis_port    = 6379

  immich_db_name = "immich"
  immich_db_user = "immich"

  immich_server_labels   = { app = "immich-server" }
  immich_ml_labels       = { app = "immich-ml" }
  immich_postgres_labels = { app = "immich-postgres" }
  immich_redis_labels    = { app = "immich-redis" }
}

# =============================================================================
# Namespace
# =============================================================================

resource "kubernetes_namespace_v1" "immich" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.immich_namespace
  }
}

# =============================================================================
# Secrets
# =============================================================================

resource "random_password" "immich_postgres_password" {
  length  = 32
  special = false
}

# Immich's system config is normally stored in the DB and edited via the admin
# UI. Mounting a JSON file at IMMICH_CONFIG_FILE makes the listed fields
# read-only in the UI so OAuth stays declarative across DB resets.
resource "kubernetes_secret_v1" "immich_config" {
  depends_on = [kubernetes_namespace_v1.immich]

  metadata {
    name      = "immich-config"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }

  data = {
    "config.json" = jsonencode({
      oauth = {
        enabled = true
        # Locked to existing Immich users only — new Keycloak identities won't
        # auto-create accounts. Add new users via the admin UI (or temporarily
        # flip this to true, log them in, then flip back).
        autoRegister            = false
        autoLaunch              = true
        buttonText              = "Login with Aether"
        clientId                = "immich"
        clientSecret            = var.immich_oauth_client_secret
        issuerUrl               = "https://auth.shdr.ch/realms/aether/.well-known/openid-configuration"
        scope                   = "openid email profile roles"
        signingAlgorithm        = "RS256"
        profileSigningAlgorithm = "none"
        storageLabelClaim       = "preferred_username"
        roleClaim               = "roles"
        mobileOverrideEnabled   = false
        mobileRedirectUri       = ""
      }
    })
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "immich_postgres" {
  depends_on = [kubernetes_namespace_v1.immich]

  metadata {
    name      = "immich-postgres"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }

  data = {
    POSTGRES_DB          = local.immich_db_name
    POSTGRES_USER        = local.immich_db_user
    POSTGRES_PASSWORD    = random_password.immich_postgres_password.result
    POSTGRES_INITDB_ARGS = "--data-checksums"
  }

  type = "Opaque"
}

# =============================================================================
# PVCs
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "immich_postgres_data" {
  depends_on = [kubernetes_namespace_v1.immich, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "immich-postgres-data"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "30Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "immich_ml_cache" {
  depends_on = [kubernetes_namespace_v1.immich, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "immich-ml-cache"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }
}

# Library lives on NFS so the 35 GB Takeout import (and growth beyond) doesn't
# sit on Ceph. Static PV pattern, like jellyfin's media-hdd.
resource "kubernetes_persistent_volume_v1" "immich_library" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "immich-library"
  }

  spec {
    capacity = { storage = "2Ti" }

    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "immich-library"
        read_only     = false
        volume_attributes = {
          server = var.nfs_server_ip
          share  = "/mnt/hdd/data/immich"
        }
      }
    }

    mount_options = ["nfsvers=4.1", "hard", "nointr"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "immich_library" {
  depends_on = [kubernetes_namespace_v1.immich, kubernetes_persistent_volume_v1.immich_library]

  metadata {
    name      = "immich-library"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.immich_library.metadata[0].name

    resources {
      requests = { storage = "2Ti" }
    }
  }
}

# Read-only PV pointing at the existing Google Takeout extraction so the
# import job can side-load files at LAN speed without copying first.
resource "kubernetes_persistent_volume_v1" "immich_takeout" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "immich-takeout"
  }

  spec {
    capacity = { storage = "100Gi" }

    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "immich-takeout"
        read_only     = true
        volume_attributes = {
          server = var.nfs_server_ip
          share  = "/mnt/hdd/data/archive/pictures/Takeout"
        }
      }
    }

    mount_options = ["nfsvers=4.1", "hard", "nointr", "ro"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "immich_takeout" {
  depends_on = [kubernetes_namespace_v1.immich, kubernetes_persistent_volume_v1.immich_takeout]

  metadata {
    name      = "immich-takeout"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.immich_takeout.metadata[0].name

    resources {
      requests = { storage = "100Gi" }
    }
  }
}

# =============================================================================
# Postgres (VectorChord + pgvecto.rs)
# =============================================================================

resource "kubernetes_stateful_set_v1" "immich_postgres" {
  depends_on = [
    kubernetes_secret_v1.immich_postgres,
    kubernetes_persistent_volume_claim_v1.immich_postgres_data,
  ]

  metadata {
    name      = "immich-postgres"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_postgres_labels
  }

  spec {
    service_name = "immich-postgres"
    replicas     = 1

    selector {
      match_labels = local.immich_postgres_labels
    }

    template {
      metadata {
        labels = local.immich_postgres_labels
      }

      spec {
        container {
          name  = "postgres"
          image = local.immich_postgres_image

          # Immich requires both VectorChord (vchord) and pgvecto.rs (vectors)
          # extensions to be loaded via shared_preload_libraries before the
          # server can run its CREATE EXTENSION migrations.
          args = [
            "postgres",
            "-c", "shared_preload_libraries=vchord.so,vectors.so",
            "-c", "search_path=\"$user\", public, vectors",
            "-c", "logging_collector=on",
            "-c", "max_wal_size=2GB",
            "-c", "shared_buffers=512MB",
            "-c", "wal_compression=on",
          ]

          port {
            container_port = local.immich_postgres_port
          }

          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.immich_postgres.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }

          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.immich_postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.immich_postgres.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          env {
            name = "POSTGRES_INITDB_ARGS"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.immich_postgres.metadata[0].name
                key  = "POSTGRES_INITDB_ARGS"
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
              memory = "4Gi"
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
            claim_name = kubernetes_persistent_volume_claim_v1.immich_postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "immich_postgres" {
  depends_on = [kubernetes_stateful_set_v1.immich_postgres]

  metadata {
    name      = "immich-postgres"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_postgres_labels
  }

  spec {
    selector = local.immich_postgres_labels

    port {
      port        = local.immich_postgres_port
      target_port = local.immich_postgres_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Redis
# =============================================================================

resource "kubernetes_deployment_v1" "immich_redis" {
  depends_on = [kubernetes_namespace_v1.immich]

  metadata {
    name      = "immich-redis"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_redis_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.immich_redis_labels
    }

    template {
      metadata {
        labels = local.immich_redis_labels
      }

      spec {
        container {
          name  = "redis"
          image = local.immich_redis_image

          port {
            container_port = local.immich_redis_port
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 15
            period_seconds        = 20
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
      }
    }
  }
}

resource "kubernetes_service_v1" "immich_redis" {
  depends_on = [kubernetes_deployment_v1.immich_redis]

  metadata {
    name      = "immich-redis"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_redis_labels
  }

  spec {
    selector = local.immich_redis_labels

    port {
      port        = local.immich_redis_port
      target_port = local.immich_redis_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Machine Learning Worker (GPU)
# =============================================================================

resource "kubernetes_deployment_v1" "immich_ml" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.immich_ml_cache,
  ]

  metadata {
    name      = "immich-ml"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_ml_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.immich_ml_labels
    }

    template {
      metadata {
        labels = local.immich_ml_labels
      }

      spec {
        runtime_class_name = "nvidia"
        node_selector      = local.gpu_node_selector

        container {
          name  = "immich-ml"
          image = local.immich_ml_image

          port {
            container_port = local.immich_ml_port
          }

          env {
            name  = "NVIDIA_VISIBLE_DEVICES"
            value = "all"
          }

          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "compute,utility"
          }

          env {
            name  = "TRANSFORMERS_CACHE"
            value = "/cache"
          }

          volume_mount {
            name       = "model-cache"
            mount_path = "/cache"
          }

          readiness_probe {
            http_get {
              path = "/ping"
              port = local.immich_ml_port
            }
            initial_delay_seconds = 30
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = local.immich_ml_port
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu              = "250m"
              memory           = "1Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              cpu              = "2"
              memory           = "4Gi"
              "nvidia.com/gpu" = "1"
            }
          }
        }

        volume {
          name = "model-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.immich_ml_cache.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "immich_ml" {
  depends_on = [kubernetes_deployment_v1.immich_ml]

  metadata {
    name      = "immich-ml"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_ml_labels
  }

  spec {
    selector = local.immich_ml_labels

    port {
      port        = local.immich_ml_port
      target_port = local.immich_ml_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Server (API + Web UI + microservices runner)
# =============================================================================

resource "kubernetes_deployment_v1" "immich_server" {
  depends_on = [
    kubernetes_service_v1.immich_postgres,
    kubernetes_service_v1.immich_redis,
    kubernetes_service_v1.immich_ml,
    kubernetes_persistent_volume_claim_v1.immich_library,
    kubernetes_secret_v1.immich_config,
  ]

  metadata {
    name      = "immich-server"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_server_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.immich_server_labels
    }

    template {
      metadata {
        labels = local.immich_server_labels
      }

      spec {
        container {
          name  = "immich-server"
          image = local.immich_server_image

          port {
            container_port = local.immich_server_port
            name           = "http"
          }

          env {
            name  = "DB_HOSTNAME"
            value = "immich-postgres.${local.immich_namespace}.svc.cluster.local"
          }

          env {
            name = "DB_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.immich_postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }

          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.immich_postgres.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          env {
            name = "DB_DATABASE_NAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.immich_postgres.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }

          env {
            name  = "REDIS_HOSTNAME"
            value = "immich-redis.${local.immich_namespace}.svc.cluster.local"
          }

          env {
            name  = "IMMICH_MACHINE_LEARNING_URL"
            value = "http://immich-ml.${local.immich_namespace}.svc.cluster.local:${local.immich_ml_port}"
          }

          env {
            name  = "IMMICH_PORT"
            value = tostring(local.immich_server_port)
          }

          env {
            name  = "UPLOAD_LOCATION"
            value = "/usr/src/app/upload"
          }

          env {
            name  = "IMMICH_CONFIG_FILE"
            value = "/etc/immich/config.json"
          }

          volume_mount {
            name       = "library"
            mount_path = "/usr/src/app/upload"
          }

          volume_mount {
            name       = "immich-config"
            mount_path = "/etc/immich"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/api/server/ping"
              port = local.immich_server_port
            }
            initial_delay_seconds = 30
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/api/server/ping"
              port = local.immich_server_port
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "4"
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "library"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.immich_library.metadata[0].name
          }
        }

        volume {
          name = "immich-config"
          secret {
            secret_name = kubernetes_secret_v1.immich_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "immich_server" {
  depends_on = [kubernetes_deployment_v1.immich_server]

  metadata {
    name      = "immich-server"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
    labels    = local.immich_server_labels
  }

  spec {
    selector = local.immich_server_labels

    port {
      port        = local.immich_server_port
      target_port = local.immich_server_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "immich_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.immich_server]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "immich"
      namespace = local.immich_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.immich_host]
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
          name = kubernetes_service_v1.immich_server.metadata[0].name
          port = local.immich_server_port
        }]
      }]
    }
  }
}
