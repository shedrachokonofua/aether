# =============================================================================
# BentoPDF — PDF Toolbox
# =============================================================================
# Stateless. No data migration needed.
# Public URL pdf.shdr.ch remains behind oauth2-proxy on the gateway.

locals {
  bentopdf_image        = "bentopdf/bentopdf-simple:latest"
  bentopdf_host = "bentopdf.home.shdr.ch"
  bentopdf_port         = 8080
  bentopdf_ns           = kubernetes_namespace_v1.personal.metadata[0].name
  bentopdf_labels       = { app = "bentopdf" }
}

resource "kubernetes_deployment_v1" "bentopdf" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "bentopdf"
    namespace = local.bentopdf_ns
    labels    = local.bentopdf_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.bentopdf_labels
    }

    template {
      metadata {
        labels = local.bentopdf_labels
      }

      spec {
        enable_service_links = false

        container {
          name  = "bentopdf"
          image = local.bentopdf_image

          port {
            container_port = local.bentopdf_port
            name           = "http"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.bentopdf_port
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "bentopdf" {
  metadata {
    name      = "bentopdf"
    namespace = local.bentopdf_ns
    labels    = local.bentopdf_labels
  }
  spec {
    selector = local.bentopdf_labels
    port {
      port = local.bentopdf_port
      target_port = local.bentopdf_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "bentopdf_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.bentopdf]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "bentopdf", namespace = local.bentopdf_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.bentopdf_host]
      rules      = [{ backendRefs = [{ name = "bentopdf", port = local.bentopdf_port }] }]
    }
  }
}
