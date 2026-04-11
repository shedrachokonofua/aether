# =============================================================================
# NZBDav — Usenet WebDAV Bridge
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Provides a WebDAV interface consumed by Jellyfin's rclone sidecar.

locals {
  nzbdav_image  = "ghcr.io/nzbdav-dev/nzbdav:latest"
  nzbdav_host   = "nzbdav.apps.home.shdr.ch"
  nzbdav_port   = 3000
  nzbdav_labels = { app = "nzbdav" }
}

# =============================================================================
# PVCs
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "nzbdav_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nzbdav-config"
    namespace = local.jellyfin_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "2Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "nzbdav_data" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nzbdav-data"
    namespace = local.jellyfin_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "20Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "nzbdav" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.nzbdav_config,
    kubernetes_persistent_volume_claim_v1.nzbdav_data,
  ]

  metadata {
    name      = "nzbdav"
    namespace = local.jellyfin_ns
    labels    = local.nzbdav_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.nzbdav_labels
    }

    template {
      metadata {
        labels = local.nzbdav_labels
      }

      spec {
        container {
          name  = "nzbdav"
          image = local.nzbdav_image

          port {
            container_port = local.nzbdav_port
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

          env {
            name  = "UPGRADE"
            value = "0.6.0"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.nzbdav_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = local.nzbdav_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nzbdav_config.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nzbdav_data.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "nzbdav" {
  metadata {
    name      = "nzbdav"
    namespace = local.jellyfin_ns
    labels    = local.nzbdav_labels
  }

  spec {
    selector = local.nzbdav_labels

    port {
      port        = local.nzbdav_port
      target_port = local.nzbdav_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "nzbdav_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.nzbdav]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "nzbdav"
      namespace = local.jellyfin_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.nzbdav_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.nzbdav.metadata[0].name
          port = local.nzbdav_port
        }]
      }]
    }
  }
}
