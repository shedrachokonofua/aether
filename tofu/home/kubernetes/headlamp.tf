# =============================================================================
# Headlamp - Kubernetes Dashboard
# =============================================================================
# Modern Kubernetes UI with OIDC authentication via Keycloak

resource "helm_release" "headlamp" {
  depends_on = [helm_release.cilium]

  name             = "headlamp"
  repository       = "https://kubernetes-sigs.github.io/headlamp/"
  chart            = "headlamp"
  namespace        = "headlamp"
  create_namespace = true
  version          = "0.39.0"
  wait             = true
  timeout          = 300

  values = [yamlencode({
    config = {
      oidc = {
        clientID  = var.oidc_client_id
        issuerURL = var.oidc_issuer_url
      }
      extraArgs = ["-oidc-callback-url", "https://headlamp.apps.home.shdr.ch/oidc-callback"]
    }

    service = {
      type = "ClusterIP"
      port = 80
    }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
    }
  })]
}

# HTTPRoute for Headlamp via Gateway API
resource "kubernetes_manifest" "headlamp_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.headlamp]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "headlamp"
      namespace = "headlamp"
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = ["headlamp.apps.home.shdr.ch"]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "headlamp"
          port = 80
        }]
      }]
    }
  }
}

