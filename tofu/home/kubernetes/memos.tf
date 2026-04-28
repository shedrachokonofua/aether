# =============================================================================
# Memos — Lightweight Notes
# =============================================================================
# Single container + sqlite stored in /var/opt/memos.
#
# Data migration: copy memos_data docker volume from Dokploy VM to k8s PVC.
# On trinity as root (use RBD snapshot method):
#   1. Mount Dokploy disk snapshot
#   2. tar /tmp/dokploy-ro/var/lib/docker/volumes/memos_data/_data → local
#   3. kubectl cp into the PVC (via a debug pod)

locals {
  memos_image        = "neosmemo/memos:stable"
  memos_host = "memos.home.shdr.ch"
  memos_port         = 5230
  memos_ns           = kubernetes_namespace_v1.personal.metadata[0].name
  memos_labels       = { app = "memos" }
}

resource "kubernetes_persistent_volume_claim_v1" "memos_data" {
  depends_on = [kubernetes_namespace_v1.personal, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "memos-data"
    namespace = local.memos_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

resource "kubernetes_deployment_v1" "memos" {
  depends_on = [kubernetes_persistent_volume_claim_v1.memos_data]

  metadata {
    name      = "memos"
    namespace = local.memos_ns
    labels    = local.memos_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = local.memos_labels
    }

    template {
      metadata { labels = local.memos_labels }

      spec {
        enable_service_links = false

        container {
          name  = "memos"
          image = local.memos_image

          env {
            name  = "MEMOS_MODE"
            value = "prod"
          }
          env {
            name  = "MEMOS_PORT"
            value = tostring(local.memos_port)
          }

          port {
            container_port = local.memos_port
            name           = "http"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/opt/memos"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.memos_port
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }
        }

        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.memos_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "memos" {
  metadata {
    name      = "memos"
    namespace = local.memos_ns
    labels    = local.memos_labels
  }
  spec {
    selector = local.memos_labels
    port {
      port = local.memos_port
      target_port = local.memos_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "memos_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.memos]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "memos", namespace = local.memos_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.memos_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "memos", port = local.memos_port }]
      }]
    }
  }
}
