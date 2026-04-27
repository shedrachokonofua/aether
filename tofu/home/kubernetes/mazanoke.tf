# =============================================================================
# Mazanoke — Image Compression Tool
# =============================================================================
# Stateless. No data migration needed.

locals {
  mazanoke_image         = "ghcr.io/civilblur/mazanoke:latest"
  mazanoke_host          = "mazanoke.home.shdr.ch"
  mazanoke_gateway_host  = "mazanoke.apps.home.shdr.ch"
  mazanoke_port          = 80
  mazanoke_ns            = kubernetes_namespace_v1.personal.metadata[0].name
  mazanoke_labels        = { app = "mazanoke" }
}

resource "kubernetes_deployment_v1" "mazanoke" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "mazanoke"
    namespace = local.mazanoke_ns
    labels    = local.mazanoke_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.mazanoke_labels
    }

    template {
      metadata {
        labels = local.mazanoke_labels
      }

      spec {
        enable_service_links = false

        container {
          name  = "mazanoke"
          image = local.mazanoke_image

          port {
            container_port = local.mazanoke_port
            name           = "http"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.mazanoke_port
            }
            initial_delay_seconds = 5
            period_seconds        = 15
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mazanoke" {
  metadata {
    name      = "mazanoke"
    namespace = local.mazanoke_ns
    labels    = local.mazanoke_labels
  }
  spec {
    selector = local.mazanoke_labels
    port {
      port = local.mazanoke_port
      target_port = local.mazanoke_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "mazanoke_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.mazanoke]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "mazanoke", namespace = local.mazanoke_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.mazanoke_gateway_host]
      rules      = [{ backendRefs = [{ name = "mazanoke", port = local.mazanoke_port }] }]
    }
  }
}
