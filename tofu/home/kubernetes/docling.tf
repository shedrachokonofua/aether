# =============================================================================
# Docling — Document Parsing & OCR
# =============================================================================
# GPU-accelerated document conversion service (PDF, DOCX, images → structured
# text). Used by OpenWebUI for content extraction.

locals {
  docling_image  = "ghcr.io/docling-project/docling-serve-cu128:main"
  docling_host   = "docling.apps.home.shdr.ch"
  docling_port   = 5001
  docling_ns     = kubernetes_namespace_v1.infra.metadata[0].name
  docling_labels = { app = "docling" }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "docling" {
  depends_on = [helm_release.nvidia_device_plugin]

  metadata {
    name      = "docling"
    namespace = local.docling_ns
    labels    = local.docling_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.docling_labels
    }

    template {
      metadata {
        labels = local.docling_labels
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_node_selector

        container {
          name  = "docling"
          image = local.docling_image

          port {
            container_port = local.docling_port
            name           = "http"
          }

          env {
            name  = "DOCLING_SERVE_ENABLE_UI"
            value = "true"
          }

          resources {
            requests = {
              cpu              = "1"
              memory           = "2Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.docling_port
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.docling_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "docling" {
  metadata {
    name      = "docling"
    namespace = local.docling_ns
    labels    = local.docling_labels
  }

  spec {
    selector = local.docling_labels

    port {
      port        = local.docling_port
      target_port = local.docling_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "docling_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "docling"
      namespace = local.docling_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.docling_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.docling.metadata[0].name
          port = local.docling_port
        }]
      }]
    }
  }
}
