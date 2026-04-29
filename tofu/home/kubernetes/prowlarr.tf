# =============================================================================
# Prowlarr — Indexer manager
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Config restored from VM export tarball into the ceph-rbd PVC after first apply.
# Existing api key + indexer settings live inside config.xml in the tarball.

locals {
  prowlarr_image  = "lscr.io/linuxserver/prowlarr:latest"
  prowlarr_host   = "prowlarr.home.shdr.ch"
  prowlarr_port   = 9696
  prowlarr_ns     = local.jellyfin_ns
  prowlarr_labels = { app = "prowlarr" }
}

# =============================================================================
# Config PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "prowlarr_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "prowlarr-config"
    namespace = local.prowlarr_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "2Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "prowlarr" {
  depends_on = [kubernetes_persistent_volume_claim_v1.prowlarr_config]

  metadata {
    name      = "prowlarr"
    namespace = local.prowlarr_ns
    labels    = local.prowlarr_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.prowlarr_labels
    }

    template {
      metadata {
        labels = local.prowlarr_labels
      }

      spec {
        container {
          name  = "prowlarr"
          image = local.prowlarr_image

          port {
            container_port = local.prowlarr_port
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

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = local.prowlarr_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.prowlarr_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.prowlarr_config.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "prowlarr" {
  metadata {
    name      = "prowlarr"
    namespace = local.prowlarr_ns
    labels    = local.prowlarr_labels
  }

  spec {
    selector = local.prowlarr_labels

    port {
      port        = local.prowlarr_port
      target_port = local.prowlarr_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "prowlarr_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.prowlarr]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "prowlarr"
      namespace = local.prowlarr_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.prowlarr_host]
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
          name = kubernetes_service_v1.prowlarr.metadata[0].name
          port = local.prowlarr_port
        }]
      }]
    }
  }
}
