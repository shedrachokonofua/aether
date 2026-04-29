# =============================================================================
# SABnzbd — Usenet downloader
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Config restored from VM export tarball into the ceph-rbd PVC after first apply.
# Downloads share the existing media-hdd NFS PVC (jellyfin) at sub_path "downloads".

locals {
  sabnzbd_image  = "lscr.io/linuxserver/sabnzbd:latest"
  sabnzbd_host   = "sabnzbd.home.shdr.ch"
  sabnzbd_port   = 8080
  sabnzbd_ns     = local.jellyfin_ns
  sabnzbd_labels = { app = "sabnzbd" }
}

# =============================================================================
# Config PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "sabnzbd_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "sabnzbd-config"
    namespace = local.sabnzbd_ns
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

resource "kubernetes_deployment_v1" "sabnzbd" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.sabnzbd_config,
    kubernetes_persistent_volume_claim_v1.media_hdd,
  ]

  metadata {
    name      = "sabnzbd"
    namespace = local.sabnzbd_ns
    labels    = local.sabnzbd_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.sabnzbd_labels
    }

    template {
      metadata {
        labels = local.sabnzbd_labels
      }

      spec {
        container {
          name  = "sabnzbd"
          image = local.sabnzbd_image

          port {
            container_port = local.sabnzbd_port
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
            name  = "HOST_WHITELIST_ENTRIES"
            value = local.sabnzbd_host
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
            sub_path   = "downloads"
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "4"
              memory = "4Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = local.sabnzbd_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.sabnzbd_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.sabnzbd_config.metadata[0].name
          }
        }

        volume {
          name = "downloads"
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

resource "kubernetes_service_v1" "sabnzbd" {
  metadata {
    name      = "sabnzbd"
    namespace = local.sabnzbd_ns
    labels    = local.sabnzbd_labels
  }

  spec {
    selector = local.sabnzbd_labels

    port {
      port        = local.sabnzbd_port
      target_port = local.sabnzbd_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "sabnzbd_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.sabnzbd]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "sabnzbd"
      namespace = local.sabnzbd_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.sabnzbd_host]
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
          name = kubernetes_service_v1.sabnzbd.metadata[0].name
          port = local.sabnzbd_port
        }]
      }]
    }
  }
}
