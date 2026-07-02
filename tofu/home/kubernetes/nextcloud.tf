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
  nextcloud_namespace     = "nextcloud"
  nextcloud_host          = "nextcloud.shdr.ch"
  nextcloud_internal_host = "nextcloud.home.shdr.ch"
  nextcloud_hosts         = [local.nextcloud_host, local.nextcloud_internal_host]
  nextcloud_config = templatefile("${path.module}/nextcloud_config.php.tftpl", {
    host          = local.nextcloud_host
    internal_host = local.nextcloud_internal_host
    service_host  = "nextcloud-server.${local.nextcloud_namespace}.svc.cluster.local"
  })
  nextcloud_config_hash = substr(sha256(local.nextcloud_config), 0, 12)

  nextcloud_server_image   = "nextcloud:34.0.0-apache"
  nextcloud_postgres_image = "postgres:16-alpine"
  nextcloud_redis_image    = "redis:7-alpine"

  # Must track the version baked into nextcloud_server_image. The install-state
  # Secret writes this into /var/www/html/config/install-state.config.php; if it
  # drifts behind the image, nextcloud goes into upgrade-required mode on every
  # pod start and the bootstrap Jobs error with "Nextcloud or one of the apps
  # require upgrade". Bump in lockstep with nextcloud_server_image.
  nextcloud_installed_version = "34.0.0.12"

  nextcloud_server_port   = 80
  nextcloud_postgres_port = 5432
  nextcloud_redis_port    = 6379

  nextcloud_db_name      = "nextcloud"
  nextcloud_db_user      = "nextcloud"
  nextcloud_cnpg_cluster = "nextcloud-cnpg"
  nextcloud_db_host      = "${local.nextcloud_cnpg_cluster}-rw.${local.nextcloud_namespace}.svc.cluster.local"

  nextcloud_nfs_share = "/mnt/hdd/data/nextcloud"

  nextcloud_oidc_provider_id = "keycloak"
  nextcloud_oidc_bootstrap_hash = nonsensitive(substr(sha256(join("|", [
    local.nextcloud_oidc_provider_id,
    var.oidc_issuer_url,
    "nextcloud",
    var.nextcloud_oauth_client_secret,
    "openid email profile",
    "preferred_username",
    "roles",
    "^(admin|nextcloud-user)$",
    "0",
  ])), 0, 12))

  nextcloud_ai_litellm_url   = "http://litellm.infra.svc.cluster.local:4000/v1"
  nextcloud_ai_default_model = "aether/gemma-4-26b-a4b"
  nextcloud_ai_bootstrap_hash = nonsensitive(substr(sha256(join("|", [
    local.nextcloud_ai_litellm_url,
    local.nextcloud_ai_default_model,
    var.secrets["litellm.virtual_keys.nextcloud"],
    "assistant=1",
    "free_prompt_picker=1",
    "text_to_image_picker=0",
    "speech_to_text_picker=0",
    "context_chat=2",
  ])), 0, 12))

  nextcloud_server_labels = { app = "nextcloud-server" }
  nextcloud_cron_labels   = { app = "nextcloud-cron" }
  nextcloud_task_worker_labels = {
    app = "nextcloud-task-worker"
  }
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
    labels = {
      "goldilocks.fairwinds.com/enabled" = "true"
    }
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
    "nextcloud-k8s.config.php" = local.nextcloud_config
  }

  type = "Opaque"
}

# Install-state Secret — values that nextcloud's installer wrote to config.php
# at first install (instanceid, secret, passwordsalt) plus the DB credentials
# the running instance actually uses. Kept separate from nextcloud-config so
# rotation of the supplemental config never touches these values. Mounted as
# /var/www/html/config/install-state.config.php in every nextcloud pod.
resource "kubernetes_secret_v1" "nextcloud_install_state" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-install-state"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    "install-state.config.php" = templatefile("${path.module}/nextcloud_install_state.config.php.tftpl", {
      passwordsalt = var.secrets["nextcloud.passwordsalt"]
      secret       = var.secrets["nextcloud.secret"]
      instanceid   = var.secrets["nextcloud.instanceid"]
      dbname       = local.nextcloud_db_name
      dbhost       = local.nextcloud_db_host
      dbuser       = "oc_admin"
      dbpassword   = var.secrets["nextcloud.dbpassword"]
      version      = local.nextcloud_installed_version
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

# LiteLLM virtual key used by Nextcloud Assistant's OpenAI-compatible provider.
resource "kubernetes_secret_v1" "nextcloud_ai" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-ai"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    LITELLM_API_KEY = var.secrets["litellm.virtual_keys.nextcloud"]
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

# Small persistent volume for App Store installs only. Bundled apps live in
# the container image at /var/www/html/apps and are read-only; user-installed
# apps land here and are referenced via apps_paths in nextcloud_config.
resource "kubernetes_persistent_volume_claim_v1" "nextcloud_custom_apps" {
  depends_on = [kubernetes_namespace_v1.nextcloud, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nextcloud-custom-apps"
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
    kubernetes_persistent_volume_claim_v1.nextcloud_custom_apps,
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
        annotations = {
          "aether.shdr.ch/config-hash" = local.nextcloud_config_hash
        }
      }

      spec {
        termination_grace_period_seconds = 120

        container {
          name  = "nextcloud"
          image = local.nextcloud_server_image

          # /var/www/html is no longer a PVC mount — the container's overlay
          # FS gets a fresh copy of the PHP code from /usr/src/nextcloud on
          # every pod start. Mount points (data, config, custom_apps, themes)
          # are excluded so the rsync doesn't stomp our persistent volumes.
          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            # Excludes match the mount points; /config is NOT excluded because
            # the image-stock config dir (CAN_INSTALL, .htaccess, .sample.php)
            # ensures /var/www/html/config is www-data-writable. Our secret
            # subPath mount of nextcloud-k8s.config.php overlays cleanly.
            rsync -rlDog --chown=www-data:www-data \
              --exclude=/data/ \
              --exclude=/custom_apps/ --exclude=/themes/ \
              /usr/src/nextcloud/ /var/www/html/
            install -d -o www-data -g www-data /var/www/html/themes
            exec apache2-foreground
          EOT
          ]

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
            value = join(" ", local.nextcloud_hosts)
          }

          env {
            name  = "POSTGRES_HOST"
            value = local.nextcloud_db_host
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
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
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

          # Hand-managed Secret with the pre-existing install state
          # (passwordsalt, secret, instanceid, dbpassword) recovered from
          # the legacy app PVC. TODO codify into tofu (see task #9).
          volume_mount {
            name       = "install-state"
            mount_path = "/var/www/html/config/install-state.config.php"
            sub_path   = "install-state.config.php"
            read_only  = true
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
            timeout_seconds       = 5
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
            timeout_seconds       = 5
          }

          # CephFS via ceph-fuse pays a metadata roundtrip per stat/open, which
          # is the worst case for PHP's `require_once` fan-out. OPcache caches
          # compiled bytecode in shared memory and (with validate_timestamps=0)
          # stops touching the filesystem after warmup. To pick up code changes
          # after a Nextcloud upgrade you have to restart the pod.
          volume_mount {
            name       = "opcache"
            mount_path = "/usr/local/etc/php/conf.d/zz-nextcloud-opcache.ini"
            sub_path   = "zz-nextcloud-opcache.ini"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1.5Gi"
            }
            limits = {
              cpu    = "2"
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_custom_apps.metadata[0].name
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

        volume {
          name = "install-state"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_install_state.metadata[0].name
            items {
              key  = "install-state.config.php"
              path = "install-state.config.php"
            }
          }
        }

        volume {
          name = "opcache"
          config_map {
            name = kubernetes_config_map_v1.nextcloud_opcache.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_config_map_v1" "nextcloud_opcache" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-opcache"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    "zz-nextcloud-opcache.ini" = <<-INI
      opcache.enable=1
      opcache.enable_cli=0
      opcache.memory_consumption=256
      opcache.interned_strings_buffer=32
      opcache.max_accelerated_files=20000
      opcache.validate_timestamps=0
      opcache.save_comments=1
      opcache.jit=tracing
      opcache.jit_buffer_size=128M
    INI
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
        annotations = {
          "aether.shdr.ch/config-hash" = local.nextcloud_config_hash
        }
      }

      spec {
        # Co-locate with the server pod so we can share the RWO custom-apps
        # PVC. RWO mounts a single node; pod affinity keeps us there.
        affinity {
          pod_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "app"
                  operator = "In"
                  values   = [local.nextcloud_server_labels.app]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        container {
          name  = "cron"
          image = local.nextcloud_server_image

          # Override the Apache entrypoint to populate /var/www/html with PHP
          # code (no longer on a PVC) and then run the built-in cron loop.
          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            # Excludes match the mount points; /config is NOT excluded because
            # the image-stock config dir (CAN_INSTALL, .htaccess, .sample.php)
            # ensures /var/www/html/config is www-data-writable. Our secret
            # subPath mount of nextcloud-k8s.config.php overlays cleanly.
            rsync -rlDog --chown=www-data:www-data \
              --exclude=/data/ \
              --exclude=/custom_apps/ --exclude=/themes/ \
              /usr/src/nextcloud/ /var/www/html/
            install -d -o www-data -g www-data /var/www/html/themes
            exec /cron.sh
          EOT
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.nextcloud_postgres.metadata[0].name
            }
          }

          env {
            name  = "POSTGRES_HOST"
            value = local.nextcloud_db_host
          }

          env {
            name  = "REDIS_HOST"
            value = "nextcloud-redis.${local.nextcloud_namespace}.svc.cluster.local"
          }

          volume_mount {
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
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

          # Hand-managed Secret with the pre-existing install state
          # (passwordsalt, secret, instanceid, dbpassword) recovered from
          # the legacy app PVC. TODO codify into tofu (see task #9).
          volume_mount {
            name       = "install-state"
            mount_path = "/var/www/html/config/install-state.config.php"
            sub_path   = "install-state.config.php"
            read_only  = true
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
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_custom_apps.metadata[0].name
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

        volume {
          name = "install-state"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_install_state.metadata[0].name
            items {
              key  = "install-state.config.php"
              path = "install-state.config.php"
            }
          }
        }
      }
    }
  }
}

# Dedicated worker for synchronous TaskProcessing providers, including
# Nextcloud Assistant. Without this, chat tasks can sit scheduled until a
# generic background job happens to execute the queue.
resource "kubernetes_deployment_v1" "nextcloud_task_worker" {
  depends_on = [kubernetes_deployment_v1.nextcloud_server]

  metadata {
    name      = "nextcloud-task-worker"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = local.nextcloud_task_worker_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.nextcloud_task_worker_labels
    }

    template {
      metadata {
        labels = local.nextcloud_task_worker_labels
        annotations = {
          "aether.shdr.ch/config-hash" = local.nextcloud_config_hash
        }
      }

      spec {
        # Co-locate with the server pod for RWO custom-apps PVC sharing.
        affinity {
          pod_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "app"
                  operator = "In"
                  values   = [local.nextcloud_server_labels.app]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        container {
          name  = "worker"
          image = local.nextcloud_server_image

          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            # Excludes match the mount points; /config is NOT excluded because
            # the image-stock config dir (CAN_INSTALL, .htaccess, .sample.php)
            # ensures /var/www/html/config is www-data-writable. Our secret
            # subPath mount of nextcloud-k8s.config.php overlays cleanly.
            rsync -rlDog --chown=www-data:www-data \
              --exclude=/data/ \
              --exclude=/custom_apps/ --exclude=/themes/ \
              /usr/src/nextcloud/ /var/www/html/
            install -d -o www-data -g www-data /var/www/html/themes
            cd /var/www/html
            while true; do
              runuser -u www-data -- php occ taskprocessing:worker --timeout=300 --interval=1
              sleep 1
            done
          EOT
          ]

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

          volume_mount {
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
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

          # Hand-managed Secret with the pre-existing install state
          # (passwordsalt, secret, instanceid, dbpassword) recovered from
          # the legacy app PVC. TODO codify into tofu (see task #9).
          volume_mount {
            name       = "install-state"
            mount_path = "/var/www/html/config/install-state.config.php"
            sub_path   = "install-state.config.php"
            read_only  = true
          }
        }

        volume {
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_custom_apps.metadata[0].name
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

        volume {
          name = "install-state"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_install_state.metadata[0].name
            items {
              key  = "install-state.config.php"
              path = "install-state.config.php"
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
# Idempotent Job: enables the `user_oidc` app and upserts the Keycloak provider.
# Runs after server is healthy. Re-running is safe; the provider command updates
# existing provider settings when the identifier is already present.

resource "kubernetes_job_v1" "nextcloud_oidc_bootstrap" {
  timeouts {
    create = "15m"
  }

  depends_on = [
    kubernetes_deployment_v1.nextcloud_server,
    kubernetes_service_v1.nextcloud_server,
    kubernetes_secret_v1.nextcloud_oidc,
  ]

  metadata {
    name      = "nextcloud-oidc-bootstrap-${local.nextcloud_oidc_bootstrap_hash}"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = { app = "nextcloud-oidc-bootstrap" }
      }

      spec {
        restart_policy = "OnFailure"

        # Co-locate with the server pod for RWO custom-apps PVC sharing.
        affinity {
          pod_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "app"
                  operator = "In"
                  values   = [local.nextcloud_server_labels.app]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        container {
          name  = "occ"
          image = local.nextcloud_server_image

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

          # Wait for /status.php to report installed=true, then run the occ
          # commands. Uses the in-cluster Service to avoid host loops.
          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            # Excludes match the mount points; /config is NOT excluded because
            # the image-stock config dir (CAN_INSTALL, .htaccess, .sample.php)
            # ensures /var/www/html/config is www-data-writable. Our secret
            # subPath mount of nextcloud-k8s.config.php overlays cleanly.
            rsync -rlDog --chown=www-data:www-data \
              --exclude=/data/ \
              --exclude=/custom_apps/ --exclude=/themes/ \
              /usr/src/nextcloud/ /var/www/html/
            install -d -o www-data -g www-data /var/www/html/themes
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
            runuser -u www-data -- php occ status

            runuser -u www-data -- php occ app:install user_oidc || runuser -u www-data -- php occ app:enable user_oidc
            runuser -u www-data -- php occ user_oidc:provider \
              --clientid="$${CLIENT_ID}" \
              --clientsecret="$${CLIENT_SECRET}" \
              --discoveryuri="$${DISCOVERY_URL}" \
              --scope="$${SCOPE}" \
              --unique-uid="$${UNIQUE_UID_ATTR}" \
              --mapping-display-name=name \
              --mapping-email=email \
              --mapping-uid="$${UNIQUE_UID_ATTR}" \
              --mapping-groups=roles \
              --group-provisioning=1 \
              --group-whitelist-regex="^(admin|nextcloud-user)$" \
              --group-restrict-login-to-whitelist=0 \
              "$${PROVIDER_ID}"
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
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
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

          # Hand-managed Secret with the pre-existing install state
          # (passwordsalt, secret, instanceid, dbpassword) recovered from
          # the legacy app PVC. TODO codify into tofu (see task #9).
          volume_mount {
            name       = "install-state"
            mount_path = "/var/www/html/config/install-state.config.php"
            sub_path   = "install-state.config.php"
            read_only  = true
          }
        }

        volume {
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_custom_apps.metadata[0].name
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

        volume {
          name = "install-state"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_install_state.metadata[0].name
            items {
              key  = "install-state.config.php"
              path = "install-state.config.php"
            }
          }
        }
      }
    }
  }

  # Re-running tofu shouldn't try to mutate a completed Job in place.
  # OIDC config changes force a new Job via the hashed name above.
  lifecycle {
    ignore_changes = [spec[0].template]
  }
}

# =============================================================================
# Post-install Assistant + LiteLLM bootstrap
# =============================================================================
# Idempotent Job: installs the Assistant and OpenAI-compatible provider apps,
# then points the provider at the in-cluster LiteLLM API with a scoped key.

resource "kubernetes_job_v1" "nextcloud_ai_bootstrap" {
  timeouts {
    create = "15m"
  }

  depends_on = [
    kubernetes_deployment_v1.nextcloud_server,
    kubernetes_service_v1.nextcloud_server,
    kubernetes_secret_v1.nextcloud_ai,
    kubernetes_service_v1.nextcloud_context_chat_backend,
  ]

  metadata {
    name      = "nextcloud-ai-bootstrap-${local.nextcloud_ai_bootstrap_hash}"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = { app = "nextcloud-ai-bootstrap" }
      }

      spec {
        restart_policy = "OnFailure"

        # Co-locate with the server pod for RWO custom-apps PVC sharing.
        affinity {
          pod_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "app"
                  operator = "In"
                  values   = [local.nextcloud_server_labels.app]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        container {
          name  = "occ"
          image = local.nextcloud_server_image

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

          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            # Excludes match the mount points; /config is NOT excluded because
            # the image-stock config dir (CAN_INSTALL, .htaccess, .sample.php)
            # ensures /var/www/html/config is www-data-writable. Our secret
            # subPath mount of nextcloud-k8s.config.php overlays cleanly.
            rsync -rlDog --chown=www-data:www-data \
              --exclude=/data/ \
              --exclude=/custom_apps/ --exclude=/themes/ \
              /usr/src/nextcloud/ /var/www/html/
            install -d -o www-data -g www-data /var/www/html/themes
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

            echo "Checking LiteLLM model endpoint..."
            curl -fsS \
              -H "Authorization: Bearer $${LITELLM_API_KEY}" \
              "$${LITELLM_URL}/models" >/tmp/litellm-models.json
            grep -q "\"$${DEFAULT_MODEL}\"" /tmp/litellm-models.json

            cd /var/www/html
            runuser -u www-data -- php occ status
            runuser -u www-data -- php occ app:install assistant || runuser -u www-data -- php occ app:enable assistant
            runuser -u www-data -- php occ app:install integration_openai || runuser -u www-data -- php occ app:enable integration_openai

            runuser -u www-data -- php occ config:app:set assistant assistant_enabled --value=1 --type=string
            runuser -u www-data -- php occ config:app:set assistant free_prompt_picker_enabled --value=1 --type=string
            runuser -u www-data -- php occ config:app:set assistant text_to_image_picker_enabled --value=0 --type=string
            runuser -u www-data -- php occ config:app:set assistant speech_to_text_picker_enabled --value=0 --type=string

            runuser -u www-data -- php occ config:app:set integration_openai url --value="$${LITELLM_URL}"
            runuser -u www-data -- php occ config:app:set integration_openai service_name --value="LiteLLM" --lazy
            runuser -u www-data -- php occ config:app:set integration_openai api_key --value="$${LITELLM_API_KEY}" --sensitive --lazy
            runuser -u www-data -- php occ config:app:set integration_openai default_completion_model_id --value="$${DEFAULT_MODEL}" --lazy
            runuser -u www-data -- php occ config:app:set integration_openai chat_endpoint_enabled --value=1 --type=string --lazy
            runuser -u www-data -- php occ config:app:set integration_openai llm_provider_enabled --value=1 --type=string --lazy
            runuser -u www-data -- php occ config:app:set integration_openai translation_provider_enabled --value=1 --type=string --lazy
            runuser -u www-data -- php occ config:app:set integration_openai t2i_provider_enabled --value=0 --type=string --lazy
            runuser -u www-data -- php occ config:app:set integration_openai stt_provider_enabled --value=0 --type=string --lazy
            runuser -u www-data -- php occ config:app:set integration_openai tts_provider_enabled --value=0 --type=string --lazy
            runuser -u www-data -- php occ config:app:set integration_openai analyze_image_provider_enabled --value=0 --type=string --lazy

            # AppAPI / Context Chat setup
            echo "Waiting for Context Chat backend to accept connections..."
            for i in $(seq 1 30); do
              if curl -s http://nextcloud-context-chat-backend.${local.nextcloud_namespace}.svc.cluster.local:10034/ >/dev/null; then
                break
              fi
              sleep 2
            done

            runuser -u www-data -- php occ app_api:daemon:list | grep -q manual_install || \
              runuser -u www-data -- php occ app_api:daemon:register \
                manual_install "Manual Install" manual-install http \
                nextcloud-context-chat-backend.${local.nextcloud_namespace}.svc.cluster.local \
                http://nextcloud-server.${local.nextcloud_namespace}.svc.cluster.local

            runuser -u www-data -- php occ app:install context_chat || runuser -u www-data -- php occ app:enable context_chat

            runuser -u www-data -- php occ app_api:app:list | grep -q context_chat_backend || \
              runuser -u www-data -- php occ app_api:app:register \
                context_chat_backend manual_install \
                --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"1.0.0\",\"secret\":\"$${CONTEXT_CHAT_BACKEND_SECRET}\",\"port\":10034}" \
                --wait-finish
          EOT
          ]

          env {
            name  = "HOST"
            value = local.nextcloud_host
          }

          env {
            name  = "LITELLM_URL"
            value = local.nextcloud_ai_litellm_url
          }

          env {
            name  = "DEFAULT_MODEL"
            value = local.nextcloud_ai_default_model
          }

          env {
            name = "LITELLM_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.nextcloud_ai.metadata[0].name
                key  = "LITELLM_API_KEY"
              }
            }
          }

          env {
            name = "CONTEXT_CHAT_BACKEND_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.nextcloud_context_chat_backend.metadata[0].name
                key  = "APP_SECRET"
              }
            }
          }

          volume_mount {
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
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

          # Hand-managed Secret with the pre-existing install state
          # (passwordsalt, secret, instanceid, dbpassword) recovered from
          # the legacy app PVC. TODO codify into tofu (see task #9).
          volume_mount {
            name       = "install-state"
            mount_path = "/var/www/html/config/install-state.config.php"
            sub_path   = "install-state.config.php"
            read_only  = true
          }
        }

        volume {
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_custom_apps.metadata[0].name
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

        volume {
          name = "install-state"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_install_state.metadata[0].name
            items {
              key  = "install-state.config.php"
              path = "install-state.config.php"
            }
          }
        }
      }
    }
  }

  # Re-running tofu shouldn't try to mutate a completed Job in place.
  # Assistant config changes force a new Job via the hashed name above.
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
      hostnames = local.nextcloud_hosts
      rules = [
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
# Context Chat Backend
# =============================================================================

resource "random_password" "nextcloud_context_chat_backend_secret" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "nextcloud_context_chat_backend" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-context-chat-backend"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    APP_SECRET = random_password.nextcloud_context_chat_backend_secret.result
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "nextcloud_context_chat_backend_data" {
  depends_on = [kubernetes_namespace_v1.nextcloud, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nextcloud-context-chat-backend-data"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "10Gi" }
    }
  }
}

resource "kubernetes_deployment_v1" "nextcloud_context_chat_backend" {
  depends_on = [
    kubernetes_namespace_v1.nextcloud,
    kubernetes_persistent_volume_claim_v1.nextcloud_context_chat_backend_data,
    kubernetes_secret_v1.nextcloud_context_chat_backend,
  ]

  metadata {
    name      = "nextcloud-context-chat-backend"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = { app = "nextcloud-context-chat-backend" }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "nextcloud-context-chat-backend" }
    }

    template {
      metadata {
        labels = { app = "nextcloud-context-chat-backend" }
      }

      spec {
        container {
          name  = "backend"
          image = "ghcr.io/nextcloud/context_chat_backend:latest"

          port {
            container_port = 10034
            name           = "http"
          }

          env {
            name  = "APP_ID"
            value = "context_chat_backend"
          }

          env {
            name  = "APP_VERSION"
            value = "1.0.0"
          }

          env {
            name  = "APP_DISPLAY_NAME"
            value = "Context Chat Backend"
          }

          env {
            name  = "APP_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "APP_PORT"
            value = "10034"
          }

          env {
            name = "APP_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.nextcloud_context_chat_backend.metadata[0].name
                key  = "APP_SECRET"
              }
            }
          }

          env {
            name  = "NEXTCLOUD_URL"
            value = "http://nextcloud-server.${local.nextcloud_namespace}.svc.cluster.local"
          }

          env {
            name  = "CC_DOWNLOAD_MODELS_FROM_HF"
            value = "true"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "2"
              memory = "2Gi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/nc_app_context_chat_backend_data"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_context_chat_backend_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "nextcloud_context_chat_backend" {
  depends_on = [kubernetes_deployment_v1.nextcloud_context_chat_backend]

  metadata {
    name      = "nextcloud-context-chat-backend"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
    labels    = { app = "nextcloud-context-chat-backend" }
  }

  spec {
    selector = { app = "nextcloud-context-chat-backend" }

    port {
      port        = 10034
      target_port = 10034
      protocol    = "TCP"
    }

    type = "ClusterIP"
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
