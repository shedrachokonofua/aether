# =============================================================================
# Radarr — Movie collection manager
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Config restored from VM export tarball into the ceph-rbd PVC after first apply.
# Library lives on the existing media-hdd NFS PVC at /media/hdd (matches the
# pre-existing root-folder paths inside the restored config DB).

locals {
  radarr_image  = "lscr.io/linuxserver/radarr:latest"
  radarr_host   = "radarr.home.shdr.ch"
  radarr_port   = 7878
  radarr_ns     = local.jellyfin_ns
  radarr_labels = { app = "radarr" }
}

# =============================================================================
# Config PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "radarr_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "radarr-config"
    namespace = local.radarr_ns
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

resource "kubernetes_deployment_v1" "radarr" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.radarr_config,
    kubernetes_persistent_volume_claim_v1.media_hdd,
  ]

  metadata {
    name      = "radarr"
    namespace = local.radarr_ns
    labels    = local.radarr_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.radarr_labels
    }

    template {
      metadata {
        labels = local.radarr_labels
      }

      spec {
        container {
          name  = "radarr"
          image = local.radarr_image

          port {
            container_port = local.radarr_port
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
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2"
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = local.radarr_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.radarr_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.radarr_config.metadata[0].name
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

resource "kubernetes_service_v1" "radarr" {
  metadata {
    name      = "radarr"
    namespace = local.radarr_ns
    labels    = local.radarr_labels
  }

  spec {
    selector = local.radarr_labels

    port {
      port        = local.radarr_port
      target_port = local.radarr_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "radarr_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.radarr]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "radarr"
      namespace = local.radarr_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.radarr_host]
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
          name = kubernetes_service_v1.radarr.metadata[0].name
          port = local.radarr_port
        }]
      }]
    }
  }
}
