# =============================================================================
# Nextcloud — Self-hosted Drive (NFS-backed)
# =============================================================================
# Stack:
#   - nextcloud-server   (Apache + PHP-FPM, Apache image)
#   - nextcloud-cron     (background job runner; cron.sh every 5m)
#   - postgres           (StatefulSet, RBD-backed)
#   - redis              (Deployment, no persistence; file lock + cache)
# Storage:
#   - user files       -> NFS (/mnt/hdd/data/nextcloud on smith) — real filenames
#   - postgres data    -> ceph-rbd (20Gi)
#   - app dir (/var/www/html: php code, custom_apps, skeleton)
#                      -> ceph-rbd (5Gi)
#
# Required out-of-band setup:
#   1. Create /mnt/hdd/data/nextcloud on the smith NFS host and export it
#      (same pattern as /mnt/hdd/data/immich)
#   2. After first deploy: the nextcloud-oidc-bootstrap Job registers Keycloak
#      as a user_oidc provider automatically
#
# Logs: errorlog stream -> stdout, captured by Loki via the OTel collector
# pattern that already runs on the cluster.

locals {
  nextcloud_namespace = "nextcloud"
  nextcloud_host      = "nextcloud.home.shdr.ch"

  nextcloud_server_image   = "nextcloud:32-apache"
  nextcloud_postgres_image = "postgres:16-alpine"
  nextcloud_redis_image    = "redis:7-alpine"

  nextcloud_server_port   = 80
  nextcloud_postgres_port = 5432
  nextcloud_redis_port    = 6379

  nextcloud_db_name = "nextcloud"
  nextcloud_db_user = "nextcloud"

  nextcloud_nfs_share = "/mnt/hdd/data/nextcloud"

  nextcloud_oidc_provider_id = "keycloak"

  nextcloud_server_labels   = { app = "nextcloud-server" }
  nextcloud_cron_labels     = { app = "nextcloud-cron" }
  nextcloud_postgres_labels = { app = "nextcloud-postgres" }
  nextcloud_redis_labels    = { app = "nextcloud-redis" }
}

# =============================================================================
# Namespace
# =============================================================================

resource "kubernetes_namespace_v1" "nextcloud" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.nextcloud_namespace
  }
}

# =============================================================================
# Secrets
# =============================================================================

resource "random_password" "nextcloud_postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "nextcloud_admin_password" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "nextcloud_postgres" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-postgres"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    POSTGRES_DB          = local.nextcloud_db_name
    POSTGRES_USER        = local.nextcloud_db_user
    POSTGRES_PASSWORD    = random_password.nextcloud_postgres_password.result
    POSTGRES_INITDB_ARGS = "--data-checksums"
  }

  type = "Opaque"
}

# Bootstrap admin — Nextcloud's installer reads NEXTCLOUD_ADMIN_USER/PASSWORD
# on first run only. After install, this secret is unused; rotate by changing
# the admin password inside the Nextcloud UI (not by re-applying tofu).
resource "kubernetes_secret_v1" "nextcloud_admin" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-admin"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    NEXTCLOUD_ADMIN_USER     = "admin"
    NEXTCLOUD_ADMIN_PASSWORD = random_password.nextcloud_admin_password.result
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data]
  }
}

# Supplemental Nextcloud config — merged at runtime as nextcloud-k8s.config.php.

# auto-generated config so settings stay declarative across image upgrades.
resource "kubernetes_secret_v1" "nextcloud_config" {
  depends_on = [
    kubernetes_namespace_v1.nextcloud,
    random_password.nextcloud_postgres_password,
  ]

  metadata {
    name      = "nextcloud-config"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    "nextcloud-k8s.config.php" = templatefile("${path.module}/nextcloud_config.php.tftpl", {
      host = local.nextcloud_host
    })
  }

  type = "Opaque"
}

# OIDC provider config consumed by the post-install Job.
# Re-runs of the Job are idempotent: it only registers the provider if absent.
resource "kubernetes_secret_v1" "nextcloud_oidc" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-oidc"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    PROVIDER_ID     = local.nextcloud_oidc_provider_id
    DISPLAY_NAME    = "Aether"
    CLIENT_ID       = "nextcloud"
    CLIENT_SECRET   = var.nextcloud_oauth_client_secret
    DISCOVERY_URL   = "${var.oidc_issuer_url}/.well-known/openid-configuration"
    SCOPE           = "openid email profile"
    UNIQUE_UID_ATTR = "preferred_username"
  }

  type = "Opaque"
}

# =============================================================================
# PVCs
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "nextcloud_postgres_data" {
  depends_on = [kubernetes_namespace_v1.nextcloud, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nextcloud-postgres-data"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "20Gi" }
    }
  }
}

# /var/www/html holds the PHP code, installed apps, custom_apps, and config.
# The data/ subdir is overlaid by the NFS mount below; only the PHP skeleton
# and .ocdata sentinel land here.
resource "kubernetes_persistent_volume_claim_v1" "nextcloud_app" {
  depends_on = [kubernetes_namespace_v1.nextcloud, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nextcloud-app"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }
}

# NFS-backed data directory — user files stored at real paths so the share is
# browsable directly from any NFS client (same pattern as immich_library).
# Create /mnt/hdd/data/nextcloud on smith before first apply.
resource "kubernetes_persistent_volume_v1" "nextcloud_data" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "nextcloud-data"
  }

  spec {
    capacity = { storage = "2Ti" }

    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "nextcloud-data"
        read_only     = false
        volume_attributes = {
          server = var.nfs_server_ip
          share  = local.nextcloud_nfs_share
        }
      }
    }

    mount_options = ["nfsvers=4.1", "hard", "nointr"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "nextcloud_data" {
  depends_on = [kubernetes_namespace_v1.nextcloud, kubernetes_persistent_volume_v1.nextcloud_data]

  metadata {
    name      = "nextcloud-data"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.nextcloud_data.metadata[0].name

    resources {
      requests = { storage = "2Ti" }
    }
  }
}

# =============================================================================
# Postgres
# =============================================================================

resource "kubernetes_stateful_set_v1" "nextcloud_postgres" {
  depends_on = [
    kubernetes_secret_v1.nextcloud_postgres,
    kubernetes_persistent_volume_claim_v1.nextcloud_postgres_data,
  ]

  metadata {
    name      = "nextcloud-postgres"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_postgres_labels
  }

  spec {
    service_name = "nextcloud-postgres"
    replicas     = 1

    selector {
      match_labels = local.nextcloud_postgres_labels
    }

    template {
      metadata {
        labels = local.nextcloud_postgres_labels
      }

      spec {
        container {
          name  = "postgres"
          image = local.nextcloud_postgres_image

          port {
            container_port = local.nextcloud_postgres_port
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.nextcloud_postgres.metadata[0].name
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
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1500m"
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
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "nextcloud_postgres" {
  depends_on = [kubernetes_stateful_set_v1.nextcloud_postgres]

  metadata {
    name      = "nextcloud-postgres"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_postgres_labels
  }

  spec {
    selector = local.nextcloud_postgres_labels

    port {
      port        = local.nextcloud_postgres_port
      target_port = local.nextcloud_postgres_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Redis (cache + distributed lock; no persistence required)
# =============================================================================

resource "kubernetes_deployment_v1" "nextcloud_redis" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-redis"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_redis_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.nextcloud_redis_labels
    }

    template {
      metadata {
        labels = local.nextcloud_redis_labels
      }

      spec {
        container {
          name  = "redis"
          image = local.nextcloud_redis_image

          args = ["--save", "", "--appendonly", "no"]

          port {
            container_port = local.nextcloud_redis_port
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
              cpu    = "30m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "300m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "nextcloud_redis" {
  depends_on = [kubernetes_deployment_v1.nextcloud_redis]

  metadata {
    name      = "nextcloud-redis"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_redis_labels
  }

  spec {
    selector = local.nextcloud_redis_labels

    port {
      port        = local.nextcloud_redis_port
      target_port = local.nextcloud_redis_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Server (Apache + PHP-FPM)
# =============================================================================

resource "kubernetes_deployment_v1" "nextcloud_server" {
  depends_on = [
    kubernetes_service_v1.nextcloud_postgres,
    kubernetes_service_v1.nextcloud_redis,
    kubernetes_persistent_volume_claim_v1.nextcloud_app,
    kubernetes_secret_v1.nextcloud_admin,
    kubernetes_secret_v1.nextcloud_config,
  ]

  metadata {
    name      = "nextcloud-server"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_server_labels
  }

  spec {
    replicas = 1

    # PHP-FPM + Apache image cannot be safely run with multiple replicas
    # against the same RBD PVC; rolling updates also confuse the installer.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.nextcloud_server_labels
    }

    template {
      metadata {
        labels = local.nextcloud_server_labels
      }

      spec {
        termination_grace_period_seconds = 120

        container {
          name  = "nextcloud"
          image = local.nextcloud_server_image

          port {
            container_port = local.nextcloud_server_port
            name           = "http"
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.nextcloud_postgres.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.nextcloud_admin.metadata[0].name
            }
          }

          # NEXTCLOUD_TRUSTED_DOMAINS is also enforced via config.php; we set
          # it here so the installer's first-run autoconfig has the value.
          env {
            name  = "NEXTCLOUD_TRUSTED_DOMAINS"
            value = local.nextcloud_host
          }

          env {
            name  = "POSTGRES_HOST"
            value = "nextcloud-postgres.${local.nextcloud_namespace}.svc.cluster.local"
          }

          env {
            name  = "REDIS_HOST"
            value = "nextcloud-redis.${local.nextcloud_namespace}.svc.cluster.local"
          }

          env {
            name  = "OVERWRITEPROTOCOL"
            value = "https"
          }

          env {
            name  = "PHP_MEMORY_LIMIT"
            value = "1024M"
          }

          env {
            name  = "PHP_UPLOAD_LIMIT"
            value = "16G"
          }

          volume_mount {
            name       = "app"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/html/data"
          }

          volume_mount {
            name       = "config"
            mount_path = "/var/www/html/config/nextcloud-k8s.config.php"
            sub_path   = "nextcloud-k8s.config.php"
          }

          readiness_probe {
            http_get {
              path = "/status.php"
              port = local.nextcloud_server_port
              http_header {
                name  = "Host"
                value = local.nextcloud_host
              }
            }
            initial_delay_seconds = 60
            period_seconds        = 15
            failure_threshold     = 6
          }

          liveness_probe {
            http_get {
              path = "/status.php"
              port = local.nextcloud_server_port
              http_header {
                name  = "Host"
                value = local.nextcloud_host
              }
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "3"
              memory = "3Gi"
            }
          }
        }

        volume {
          name = "app"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_app.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_config.metadata[0].name
            items {
              key  = "nextcloud-k8s.config.php"
              path = "nextcloud-k8s.config.php"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "nextcloud_server" {
  depends_on = [kubernetes_deployment_v1.nextcloud_server]

  metadata {
    name      = "nextcloud-server"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_server_labels
  }

  spec {
    selector = local.nextcloud_server_labels

    port {
      port        = local.nextcloud_server_port
      target_port = local.nextcloud_server_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Cron (Nextcloud background jobs)
# =============================================================================
# Runs cron.sh every 5 minutes inside the same image as the server, sharing
# the app PVC. Nextcloud admin > Basic Settings should be set to "Cron"
# (default, but worth knowing) so that scheduled tasks run via this loop.

resource "kubernetes_deployment_v1" "nextcloud_cron" {
  depends_on = [kubernetes_deployment_v1.nextcloud_server]

  metadata {
    name      = "nextcloud-cron"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_cron_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.nextcloud_cron_labels
    }

    template {
      metadata {
        labels = local.nextcloud_cron_labels
      }

      spec {
        container {
          name  = "cron"
          image = local.nextcloud_server_image

          # The image entrypoint runs Apache by default; override to run the
          # built-in cron.sh which loops every 5 minutes.
          command = ["/cron.sh"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.nextcloud_postgres.metadata[0].name
            }
          }

          env {
            name  = "POSTGRES_HOST"
            value = "nextcloud-postgres.${local.nextcloud_namespace}.svc.cluster.local"
          }

          env {
            name  = "REDIS_HOST"
            value = "nextcloud-redis.${local.nextcloud_namespace}.svc.cluster.local"
          }

          volume_mount {
            name       = "app"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/html/data"
          }

          volume_mount {
            name       = "config"
            mount_path = "/var/www/html/config/nextcloud-k8s.config.php"
            sub_path   = "nextcloud-k8s.config.php"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "app"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_app.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_config.metadata[0].name
            items {
              key  = "nextcloud-k8s.config.php"
              path = "nextcloud-k8s.config.php"
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Post-install OIDC bootstrap
# =============================================================================
# Idempotent Job: enables the `user_oidc` app and registers the Keycloak
# provider only if it isn't already registered. Runs once after server is
# healthy. Re-running is safe; the script bails early if the provider exists.

resource "kubernetes_job_v1" "nextcloud_oidc_bootstrap" {
  depends_on = [
    kubernetes_deployment_v1.nextcloud_server,
    kubernetes_service_v1.nextcloud_server,
    kubernetes_secret_v1.nextcloud_oidc,
  ]

  metadata {
    name      = "nextcloud-oidc-bootstrap"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit              = 6
    ttl_seconds_after_finished = 86400

    template {
      metadata {
        labels = { app = "nextcloud-oidc-bootstrap" }
      }

      spec {
        restart_policy = "OnFailure"

        # The Job needs the same code volume as the server because `occ` is
        # in /var/www/html. We mount the existing PVC RWO, so the Job is
        # serialized after the server pod is healthy.
        container {
          name  = "occ"
          image = local.nextcloud_server_image

          # Wait for /status.php to report installed=true, then run the occ
          # commands. Uses the in-cluster Service to avoid host loops.
          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            echo "Waiting for Nextcloud server to be installed..."
            for i in $(seq 1 60); do
              code=$(curl -s -o /tmp/status.json -w '%%{http_code}' \
                -H "Host: $${HOST}" \
                http://nextcloud-server.${local.nextcloud_namespace}.svc.cluster.local/status.php || true)
              if [ "$code" = "200" ] && grep -q '"installed":true' /tmp/status.json; then
                break
              fi
              sleep 5
            done
            cd /var/www/html
            php occ status

            php occ app:install user_oidc || php occ app:enable user_oidc
            if php occ user_oidc:provider | grep -q "$${PROVIDER_ID}"; then
              echo "user_oidc provider $${PROVIDER_ID} already exists, skipping create"
            else
              php occ user_oidc:provider \
                --clientid="$${CLIENT_ID}" \
                --clientsecret="$${CLIENT_SECRET}" \
                --discoveryuri="$${DISCOVERY_URL}" \
                --scope="$${SCOPE}" \
                --unique-uid="$${UNIQUE_UID_ATTR}" \
                --mapping-display-name=name \
                --mapping-email=email \
                --mapping-uid="$${UNIQUE_UID_ATTR}" \
                "$${PROVIDER_ID}"
            fi
          EOT
          ]

          env {
            name  = "HOST"
            value = local.nextcloud_host
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.nextcloud_oidc.metadata[0].name
            }
          }

          volume_mount {
            name       = "app"
            mount_path = "/var/www/html"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/html/data"
          }

          volume_mount {
            name       = "config"
            mount_path = "/var/www/html/config/nextcloud-k8s.config.php"
            sub_path   = "nextcloud-k8s.config.php"
          }
        }

        volume {
          name = "app"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_app.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_config.metadata[0].name
            items {
              key  = "nextcloud-k8s.config.php"
              path = "nextcloud-k8s.config.php"
            }
          }
        }
      }
    }
  }

  # Re-running tofu shouldn't try to recreate a completed Job in place.
  # Bumping the OIDC config will force a new Job via name change if needed.
  lifecycle {
    ignore_changes = [spec[0].template]
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "nextcloud_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.nextcloud_server]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "nextcloud"
      namespace = local.nextcloud_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.nextcloud_host]
      rules = [
        # Nextcloud's WebDAV/CalDAV/CardDAV mobile clients hit /.well-known
        # paths that must redirect to /remote.php/dav/. The image ships an
        # Apache rewrite rule but it only applies via the canonical host.
        {
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
                { name = "X-Forwarded-Proto", value = "https" },
                { name = "X-Forwarded-Host", value = local.nextcloud_host },
              ]
            }
          }]
          backendRefs = [{
            kind = "Service"
            name = kubernetes_service_v1.nextcloud_server.metadata[0].name
            port = local.nextcloud_server_port
          }]
        },
      ]
    }
  }
}

# =============================================================================
# Outputs
# =============================================================================
# Surface the bootstrap admin password so the operator can grab it once with
# `tofu output -raw nextcloud_admin_password`. Rotate the admin password
# inside Nextcloud after first login; the Tofu-tracked value becomes stale
# (intentional, see lifecycle on nextcloud_admin secret).

output "nextcloud_admin_password" {
  value     = random_password.nextcloud_admin_password.result
  sensitive = true
}

output "nextcloud_url" {
  value = "https://${local.nextcloud_host}"
}
