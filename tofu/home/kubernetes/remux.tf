# =============================================================================
# Remux — media remuxing service
# =============================================================================

locals {
  remux_image  = "ghcr.io/lostb1t/remux:0.19.0"
  remux_host   = "remux.home.shdr.ch"
  remux_port   = 3000
  remux_ns     = local.media_ns
  remux_labels = { app = "remux" }
}

# =============================================================================
# PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "remux_data" {
  depends_on = [module.namespace["media"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "remux-data"
    namespace = local.remux_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "2Gi" }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "remux" {
  depends_on = [kubernetes_persistent_volume_claim_v1.remux_data]

  metadata {
    name      = "remux"
    namespace = local.remux_ns
    labels    = local.remux_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.remux_labels
    }

    template {
      metadata {
        labels = local.remux_labels
      }

      spec {
        container {
          name  = "remux"
          image = local.remux_image

          port {
            container_port = local.remux_port
            name           = "http"
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
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
              cpu    = "2"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/system/info/public"
              port = local.remux_port
            }
            period_seconds  = 30
            timeout_seconds = 2
          }

          readiness_probe {
            http_get {
              path = "/system/info/public"
              port = local.remux_port
            }
            period_seconds  = 10
            timeout_seconds = 2
          }

          startup_probe {
            http_get {
              path = "/system/info/public"
              port = local.remux_port
            }
            failure_threshold = 30
            period_seconds    = 2
            timeout_seconds   = 2
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.remux_data.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "remux" {
  metadata {
    name      = "remux"
    namespace = local.remux_ns
    labels    = local.remux_labels
  }

  spec {
    selector = local.remux_labels

    port {
      port        = local.remux_port
      target_port = local.remux_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "remux_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.remux]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "remux"
      namespace = local.remux_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.remux_host]
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
          name = kubernetes_service_v1.remux.metadata[0].name
          port = local.remux_port
        }]
      }]
    }
  }
}
