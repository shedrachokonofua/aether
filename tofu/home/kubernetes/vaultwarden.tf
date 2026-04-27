# =============================================================================
# Vaultwarden — Self-hosted Bitwarden
# =============================================================================
# Single container + sqlite in /data.
#
# Data migration: you have a Bitwarden export in ~/Downloads.
# Simplest approach: deploy fresh, log in as admin, import the export.
# If you want full data continuity (history, shares, attachments), copy the
# docker volume: vaultwarden-default-vaultwarden-fuyfhc → vaultwarden-data PVC.
#
# Security: SIGNUPS_ALLOWED was true in Dokploy — set to false here.

resource "random_password" "vaultwarden_admin_token" {
  length  = 48
  special = false
}

locals {
  vaultwarden_image        = "vaultwarden/server:latest"
  vaultwarden_gateway_host = "vaultwarden.apps.home.shdr.ch"
  vaultwarden_host         = "vaultwarden.home.shdr.ch"
  vaultwarden_port         = 80
  vaultwarden_ns           = kubernetes_namespace_v1.personal.metadata[0].name
  vaultwarden_labels       = { app = "vaultwarden" }
}

resource "kubernetes_secret_v1" "vaultwarden_env" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "vaultwarden-env"
    namespace = local.vaultwarden_ns
  }

  data = {
    DOMAIN             = "https://${local.vaultwarden_host}"
    SIGNUPS_ALLOWED    = "false"
    ADMIN_TOKEN        = random_password.vaultwarden_admin_token.result
    WEBSOCKET_ENABLED  = "true"
    ROCKET_PORT        = tostring(local.vaultwarden_port)
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data["ADMIN_TOKEN"]]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "vaultwarden_data" {
  depends_on = [kubernetes_namespace_v1.personal, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "vaultwarden-data"
    namespace = local.vaultwarden_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "vaultwarden" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.vaultwarden_data,
    kubernetes_secret_v1.vaultwarden_env,
  ]

  metadata {
    name      = "vaultwarden"
    namespace = local.vaultwarden_ns
    labels    = local.vaultwarden_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = local.vaultwarden_labels
    }

    template {
      metadata { labels = local.vaultwarden_labels }

      spec {
        enable_service_links = false

        container {
          name  = "vaultwarden"
          image = local.vaultwarden_image

          env_from {
            secret_ref { name = kubernetes_secret_v1.vaultwarden_env.metadata[0].name }
          }

          port {
            container_port = local.vaultwarden_port
            name           = "http"
          }
          port {
            container_port = 3012
            name           = "websocket"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.vaultwarden_port
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }
        }

        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.vaultwarden_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "vaultwarden" {
  metadata {
    name      = "vaultwarden"
    namespace = local.vaultwarden_ns
    labels    = local.vaultwarden_labels
  }
  spec {
    selector = local.vaultwarden_labels
    port {
      port = local.vaultwarden_port
      target_port = local.vaultwarden_port
      name = "http"
    }
    port {
      port = 3012
      target_port = 3012
      name = "websocket"
    }
  }
}

resource "kubernetes_manifest" "vaultwarden_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.vaultwarden]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "vaultwarden", namespace = local.vaultwarden_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.vaultwarden_gateway_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" },
              { name = "X-Forwarded-Host", value = local.vaultwarden_host },
            ]
          }
        }]
        backendRefs = [{ name = "vaultwarden", port = local.vaultwarden_port }]
      }]
    }
  }
}

output "vaultwarden_admin_token" {
  value     = random_password.vaultwarden_admin_token.result
  sensitive = true
}
