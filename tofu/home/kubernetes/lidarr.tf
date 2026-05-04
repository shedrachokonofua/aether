# =============================================================================
# Lidarr — Music collection manager
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Config restored from VM export tarball into the ceph-rbd PVC after first apply.
# Library lives on the existing media-hdd NFS PVC at /media/hdd (matches the
# pre-existing root-folder paths inside the restored config DB).

locals {
  lidarr_image  = "lscr.io/linuxserver/lidarr:latest"
  lidarr_host   = "lidarr.home.shdr.ch"
  lidarr_port   = 8686
  lidarr_ns     = local.jellyfin_ns
  lidarr_labels = { app = "lidarr" }
}

# =============================================================================
# Config PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "lidarr_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "lidarr-config"
    namespace = local.lidarr_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "lidarr" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.lidarr_config,
    kubernetes_persistent_volume_claim_v1.media_hdd,
  ]

  metadata {
    name      = "lidarr"
    namespace = local.lidarr_ns
    labels    = local.lidarr_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.lidarr_labels
    }

    template {
      metadata {
        labels = local.lidarr_labels
      }

      spec {
        container {
          name  = "lidarr"
          image = local.lidarr_image

          port {
            container_port = local.lidarr_port
            name           = "http"
          }

          env {
            name  = "PUID"
            value = "1000"
          }

          env {
            name  = "PGID"
            value = "1000"
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "media-hdd"
            mount_path = "/media/hdd"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "384Mi"
            }
            limits = {
              cpu    = "2"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = local.lidarr_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.lidarr_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.lidarr_config.metadata[0].name
          }
        }

        volume {
          name = "media-hdd"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.media_hdd.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "lidarr" {
  metadata {
    name      = "lidarr"
    namespace = local.lidarr_ns
    labels    = local.lidarr_labels
  }

  spec {
    selector = local.lidarr_labels

    port {
      port        = local.lidarr_port
      target_port = local.lidarr_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "lidarr_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.lidarr]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "lidarr"
      namespace = local.lidarr_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.lidarr_host]
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
          name = kubernetes_service_v1.lidarr.metadata[0].name
          port = local.lidarr_port
        }]
      }]
    }
  }
}
