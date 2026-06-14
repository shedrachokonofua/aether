# =============================================================================
# Matrix — Synapse + Element + mautrix bridges + Postgres
# =============================================================================
# Migrated off the messaging-stack VM (vmid 1016, podman quadlet pod). See
# docs/worklogs/messaging-stack-migration.md for the data-migration recipe.
#
# Layout:
#   - matrix-postgres   StatefulSet (cluster convention; miniflux.tf shape)
#   - matrix            Deployment, single Pod, 4 containers (synapse + element
#                       + mautrix-whatsapp + mautrix-gmessages). Multi-container
#                       because synapse needs to read each bridge's
#                       registration.yaml, which lives in the bridge's PVC —
#                       RWO PVCs can be mounted into multiple containers within
#                       the same Pod.
#
# hermes-bots (infra ns) keep working unchanged — they hit matrix.home.shdr.ch
# through Caddy, which gets re-pointed at the cluster Gateway VIP post-cutover.

resource "kubernetes_namespace_v1" "matrix" {
  depends_on = [helm_release.cilium]
  metadata {
    name = "matrix"
    labels = {
      "goldilocks.fairwinds.com/enabled" = "true"
    }
  }
}

locals {
  # Pin postgres minor to match (or exceed) the source VM's version. The source
  # uses `postgres:alpine` (unpinned) — confirm version with
  #   ssh aether@10.0.3.4 'podman exec postgres pg_dumpall --version'
  # before tofu apply. pg_restore from newer dump → older server fails.
  matrix_postgres_image   = "postgres:17-alpine"
  synapse_image           = "docker.io/matrixdotorg/synapse:latest"
  element_image           = "docker.io/vectorim/element-web:latest"
  mautrix_whatsapp_image  = "dock.mau.dev/mautrix/whatsapp:latest"
  mautrix_gmessages_image = "dock.mau.dev/mautrix/gmessages:latest"

  matrix_ns        = kubernetes_namespace_v1.matrix.metadata[0].name
  matrix_labels    = { app = "matrix" }
  matrix_pg_labels = { app = "matrix-postgres" }

  matrix_host  = "matrix.home.shdr.ch"
  element_host = "element.home.shdr.ch"

  synapse_port         = 8008
  synapse_metrics_port = 9091
  element_port         = 8080
  matrix_pg_port       = 5432

  matrix_pg_service = "matrix-postgres.${local.matrix_ns}.svc.cluster.local"
  matrix_pg_user    = var.secrets["matrix.database_user"]
}

# =============================================================================
# Postgres — Secret, PVC, StatefulSet, Service, init ConfigMap
# =============================================================================

resource "kubernetes_secret_v1" "matrix_postgres" {
  depends_on = [kubernetes_namespace_v1.matrix]
  metadata {
    name      = "matrix-postgres"
    namespace = local.matrix_ns
  }
  type = "Opaque"
  data = {
    POSTGRES_USER     = local.matrix_pg_user
    POSTGRES_PASSWORD = var.secrets["matrix.database_password"]
    # Synapse db name == user (matches existing homeserver.yaml convention).
    POSTGRES_DB = local.matrix_pg_user
    # Synapse requires C collation for the main DB.
    POSTGRES_INITDB_ARGS = "--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
  }
}

resource "kubernetes_config_map_v1" "matrix_postgres_init" {
  depends_on = [kubernetes_namespace_v1.matrix]
  metadata {
    name      = "matrix-postgres-init"
    namespace = local.matrix_ns
  }
  data = {
    # Only runs on a fresh pgdata dir. Per-DB restore later won't re-trigger
    # this. Matches the existing init-matrix-bridge-dbs.sql.j2 layout.
    "01-init-bridge-dbs.sql" = <<-EOT
      CREATE DATABASE mautrix_whatsapp;
      GRANT ALL PRIVILEGES ON DATABASE mautrix_whatsapp TO ${local.matrix_pg_user};

      CREATE DATABASE mautrix_gmessages;
      GRANT ALL PRIVILEGES ON DATABASE mautrix_gmessages TO ${local.matrix_pg_user};
    EOT
  }
}

resource "kubernetes_persistent_volume_claim_v1" "matrix_postgres_data" {
  depends_on = [kubernetes_namespace_v1.matrix, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name      = "matrix-postgres-data"
    namespace = local.matrix_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "10Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_stateful_set_v1" "matrix_postgres" {
  depends_on = [
    kubernetes_secret_v1.matrix_postgres,
    kubernetes_config_map_v1.matrix_postgres_init,
    kubernetes_persistent_volume_claim_v1.matrix_postgres_data,
  ]
  metadata {
    name      = "matrix-postgres"
    namespace = local.matrix_ns
    labels    = local.matrix_pg_labels
  }
  spec {
    service_name = "matrix-postgres"
    replicas     = 1
    selector { match_labels = local.matrix_pg_labels }
    template {
      metadata { labels = local.matrix_pg_labels }
      spec {
        container {
          name  = "postgres"
          image = local.matrix_postgres_image
          env_from {
            secret_ref { name = kubernetes_secret_v1.matrix_postgres.metadata[0].name }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port { container_port = local.matrix_pg_port }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          volume_mount {
            name       = "init"
            mount_path = "/docker-entrypoint-initdb.d"
          }
          readiness_probe {
            exec { command = ["/bin/sh", "-c", "pg_isready -U ${local.matrix_pg_user} -d ${local.matrix_pg_user}"] }
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
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.matrix_postgres_data.metadata[0].name }
        }
        volume {
          name = "init"
          config_map { name = kubernetes_config_map_v1.matrix_postgres_init.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "matrix_postgres" {
  depends_on = [kubernetes_stateful_set_v1.matrix_postgres]
  metadata {
    name      = "matrix-postgres"
    namespace = local.matrix_ns
    labels    = local.matrix_pg_labels
  }
  spec {
    selector = local.matrix_pg_labels
    port {
      port        = local.matrix_pg_port
      target_port = local.matrix_pg_port
    }
    type = "ClusterIP"
  }
}

# =============================================================================
# Synapse — ConfigMap (rendered) + Secret (signing key + doublepuppet) + PVC
# =============================================================================

resource "kubernetes_config_map_v1" "synapse_config" {
  depends_on = [kubernetes_namespace_v1.matrix]
  metadata {
    name      = "synapse-config"
    namespace = local.matrix_ns
  }
  data = {
    "homeserver.yaml" = templatefile("${path.module}/matrix_homeserver.yaml.tftpl", {
      server_name                = local.matrix_host
      synapse_port               = local.synapse_port
      synapse_metrics_port       = local.synapse_metrics_port
      db_host                    = local.matrix_pg_service
      db_port                    = local.matrix_pg_port
      db_user                    = local.matrix_pg_user
      db_password                = var.secrets["matrix.database_password"]
      registration_shared_secret = var.secrets["matrix.registration_shared_secret"]
      macaroon_secret_key        = var.secrets["matrix.macaroon_secret_key"]
      form_secret                = var.secrets["matrix.form_secret"]
      # Keycloak SSO (client managed in tofu/home/keycloak.tf). Not
      # var.oidc_client_id — that's the kube-apiserver OIDC client.
      oidc_issuer        = var.oidc_issuer_url
      oidc_client_id     = "matrix"
      oidc_client_secret = var.matrix_oauth_client_secret
    })
    # Static; copy of ansible/playbooks/messaging_stack/files/synapse-log.config.
    "${local.matrix_host}.log.config" = <<-EOT
      version: 1
      formatters:
        precise:
          format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
      handlers:
        console:
          class: logging.StreamHandler
          formatter: precise
      loggers:
        _placeholder:
          level: "INFO"
        synapse.storage.SQL:
          # beware: increasing this to DEBUG will make synapse log sensitive
          # information such as access tokens.
          level: INFO
      root:
        level: INFO
        handlers: [console]
      disable_existing_loggers: false
    EOT
  }
}

resource "kubernetes_secret_v1" "synapse_secrets" {
  depends_on = [kubernetes_namespace_v1.matrix]
  metadata {
    name      = "synapse-secrets"
    namespace = local.matrix_ns
  }
  type = "Opaque"
  data = {
    "${local.matrix_host}.signing.key" = var.secrets["matrix.signing_key"]
    # AS registration for the bridges' double-puppeting. Mirrors the existing
    # ansible/playbooks/messaging_stack/templates/doublepuppet.yaml.j2.
    "doublepuppet.yaml" = <<-EOT
      id: doublepuppet
      url:
      as_token: ${var.secrets["matrix.doublepuppet_as_token"]}
      hs_token: ${var.secrets["matrix.doublepuppet_hs_token"]}
      sender_localpart: ${var.secrets["matrix.doublepuppet_sender_localpart"]}
      rate_limited: false
      namespaces:
        users:
          - regex: '@.*:${local.matrix_host}'
            exclusive: false
    EOT
  }
}

resource "kubernetes_persistent_volume_claim_v1" "synapse_data" {
  depends_on = [kubernetes_namespace_v1.matrix, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name      = "synapse-data"
    namespace = local.matrix_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    # media_store can grow; resize before restore if the tarball is large.
    resources { requests = { storage = "20Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

# =============================================================================
# Element — ConfigMap (static)
# =============================================================================

resource "kubernetes_config_map_v1" "element_config" {
  depends_on = [kubernetes_namespace_v1.matrix]
  metadata {
    name      = "element-config"
    namespace = local.matrix_ns
  }
  data = {
    "config.json" = jsonencode({
      default_server_config = {
        "m.homeserver" = {
          base_url = "https://${local.matrix_host}"
        }
      }
      brand               = "Element"
      default_theme       = "light"
      roomDirectory       = { servers = [local.matrix_host] }
      disable_custom_urls = false
      disable_guests      = false
      disable_3pid_login  = true
    })
  }
}

# =============================================================================
# Mautrix bridge PVCs (one per bridge — also mounted ro into synapse so
# synapse can read registration.yaml)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "mautrix_whatsapp_data" {
  depends_on = [kubernetes_namespace_v1.matrix, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name      = "mautrix-whatsapp-data"
    namespace = local.matrix_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_persistent_volume_claim_v1" "mautrix_gmessages_data" {
  depends_on = [kubernetes_namespace_v1.matrix, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name      = "mautrix-gmessages-data"
    namespace = local.matrix_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

# =============================================================================
# Matrix Deployment (single Pod — synapse + element + 2 bridges)
# =============================================================================

resource "kubernetes_deployment_v1" "matrix" {
  depends_on = [
    kubernetes_service_v1.matrix_postgres,
    kubernetes_secret_v1.synapse_secrets,
    kubernetes_config_map_v1.synapse_config,
    kubernetes_config_map_v1.element_config,
    kubernetes_persistent_volume_claim_v1.synapse_data,
    kubernetes_persistent_volume_claim_v1.mautrix_whatsapp_data,
    kubernetes_persistent_volume_claim_v1.mautrix_gmessages_data,
  ]

  metadata {
    name      = "matrix"
    namespace = local.matrix_ns
    labels    = local.matrix_labels
  }

  spec {
    replicas = 1
    # RWO PVCs shared across containers in this Pod — must hand them off
    # cleanly across rollouts.
    strategy { type = "Recreate" }

    selector { match_labels = local.matrix_labels }

    template {
      metadata {
        labels = local.matrix_labels
        annotations = {
          # Restart the pod when homeserver.yaml changes — the subPath mount
          # never refreshes in-place (same pattern as litellm.tf/mux.tf).
          "aether.shdr.ch/config-sha" = sha256(kubernetes_config_map_v1.synapse_config.data["homeserver.yaml"])
        }
      }

      spec {
        # ---------------------------------------------------------------------
        # Synapse
        # ---------------------------------------------------------------------
        container {
          name  = "synapse"
          image = local.synapse_image

          env {
            name  = "SYNAPSE_CONFIG_PATH"
            value = "/etc/synapse/homeserver.yaml"
          }
          env {
            name  = "UID"
            value = "0"
          }
          env {
            name  = "GID"
            value = "0"
          }

          port {
            container_port = local.synapse_port
            name           = "client"
          }
          port {
            container_port = local.synapse_metrics_port
            name           = "metrics"
          }

          volume_mount {
            name       = "synapse-config"
            mount_path = "/etc/synapse/homeserver.yaml"
            sub_path   = "homeserver.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "synapse-config"
            mount_path = "/etc/synapse/${local.matrix_host}.log.config"
            sub_path   = "${local.matrix_host}.log.config"
            read_only  = true
          }
          volume_mount {
            name       = "synapse-secrets"
            mount_path = "/etc/synapse/${local.matrix_host}.signing.key"
            sub_path   = "${local.matrix_host}.signing.key"
            read_only  = true
          }
          volume_mount {
            name       = "synapse-secrets"
            mount_path = "/etc/synapse/doublepuppet.yaml"
            sub_path   = "doublepuppet.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "synapse-data"
            mount_path = "/data"
          }
          # Bridge registration files (written by the bridge containers).
          volume_mount {
            name       = "mautrix-whatsapp-data"
            mount_path = "/srv/whatsapp/registration.yaml"
            sub_path   = "registration.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "mautrix-gmessages-data"
            mount_path = "/srv/gmessages/registration.yaml"
            sub_path   = "registration.yaml"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.synapse_port
            }
            initial_delay_seconds = 30
            period_seconds        = 15
            failure_threshold     = 4
          }
          # Intentionally no liveness probe yet — a synapse restart cycles all
          # 4 containers. Revisit after a week of soak.

          resources {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
        }

        # ---------------------------------------------------------------------
        # Element web
        # ---------------------------------------------------------------------
        container {
          name  = "element"
          image = local.element_image

          env {
            name  = "ELEMENT_WEB_PORT"
            value = tostring(local.element_port)
          }

          port {
            container_port = local.element_port
            name           = "http"
          }

          volume_mount {
            name       = "element-config"
            mount_path = "/app/config.json"
            sub_path   = "config.json"
            read_only  = true
          }

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
        }

        # ---------------------------------------------------------------------
        # mautrix-whatsapp
        # ---------------------------------------------------------------------
        container {
          name  = "mautrix-whatsapp"
          image = local.mautrix_whatsapp_image

          volume_mount {
            name       = "mautrix-whatsapp-data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }

        # ---------------------------------------------------------------------
        # mautrix-gmessages
        # ---------------------------------------------------------------------
        container {
          name  = "mautrix-gmessages"
          image = local.mautrix_gmessages_image

          volume_mount {
            name       = "mautrix-gmessages-data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }

        # ---------------------------------------------------------------------
        # Volumes
        # ---------------------------------------------------------------------
        volume {
          name = "synapse-config"
          config_map { name = kubernetes_config_map_v1.synapse_config.metadata[0].name }
        }
        volume {
          name = "synapse-secrets"
          secret { secret_name = kubernetes_secret_v1.synapse_secrets.metadata[0].name }
        }
        volume {
          name = "synapse-data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.synapse_data.metadata[0].name }
        }
        volume {
          name = "element-config"
          config_map { name = kubernetes_config_map_v1.element_config.metadata[0].name }
        }
        volume {
          name = "mautrix-whatsapp-data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.mautrix_whatsapp_data.metadata[0].name }
        }
        volume {
          name = "mautrix-gmessages-data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.mautrix_gmessages_data.metadata[0].name }
        }
      }
    }
  }
}

# =============================================================================
# Services
# =============================================================================

resource "kubernetes_service_v1" "synapse" {
  depends_on = [kubernetes_deployment_v1.matrix]
  metadata {
    name      = "synapse"
    namespace = local.matrix_ns
    labels    = local.matrix_labels
  }
  spec {
    selector = local.matrix_labels
    port {
      name        = "client"
      port        = local.synapse_port
      target_port = local.synapse_port
    }
    port {
      name        = "metrics"
      port        = local.synapse_metrics_port
      target_port = local.synapse_metrics_port
    }
  }
}

resource "kubernetes_service_v1" "element" {
  depends_on = [kubernetes_deployment_v1.matrix]
  metadata {
    name      = "element"
    namespace = local.matrix_ns
    labels    = local.matrix_labels
  }
  spec {
    selector = local.matrix_labels
    port {
      name        = "http"
      port        = local.element_port
      target_port = local.element_port
    }
  }
}

# =============================================================================
# HTTPRoutes — Gateway API
# =============================================================================

# Mirrors the Caddy block: only /_matrix/* and /_synapse/client/* hit Synapse.
# The Synapse admin API (/_synapse/admin) stays unreachable from the public
# Gateway.
resource "kubernetes_manifest" "matrix_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.synapse]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "matrix", namespace = local.matrix_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.matrix_host]
      rules = [{
        matches = [
          { path = { type = "PathPrefix", value = "/_matrix" } },
          { path = { type = "PathPrefix", value = "/_synapse/client" } },
        ]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "synapse", port = local.synapse_port }]
      }]
    }
  }
}

resource "kubernetes_manifest" "element_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.element]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "element", namespace = local.matrix_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.element_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "element", port = local.element_port }]
      }]
    }
  }
}
