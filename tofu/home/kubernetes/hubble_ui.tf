# =============================================================================
# Hubble UI - Expose via Gateway API
# =============================================================================
# Cilium's Hubble UI routed through the cluster Gateway

resource "kubernetes_manifest" "hubble_ui_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.cilium]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "hubble-ui"
      namespace = "kube-system"
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = ["hubble.apps.home.shdr.ch"]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "hubble-ui"
          port = 80
        }]
      }]
    }
  }
}


