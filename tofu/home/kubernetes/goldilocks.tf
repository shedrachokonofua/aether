# =============================================================================
# Goldilocks + VPA Recommender
# =============================================================================
# Resource right-sizing advisor only. VPA updater and admission controller stay
# disabled so recommendations are reviewed and copied back into Tofu instead of
# mutating or evicting Pods at runtime.

resource "kubernetes_namespace_v1" "goldilocks" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "goldilocks"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "helm_release" "vpa_recommender" {
  depends_on = [
    kubernetes_namespace_v1.goldilocks,
    helm_release.metrics_server,
  ]

  name       = "vpa"
  repository = "https://charts.fairwinds.com/stable"
  chart      = "vpa"
  namespace  = kubernetes_namespace_v1.goldilocks.metadata[0].name
  version    = "4.12.0"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    metrics-server = { enabled = false }

    recommender = {
      enabled = true
      resources = {
        requests = {
          cpu    = "50m"
          memory = "500Mi"
        }
      }
    }

    updater = { enabled = false }

    admissionController = {
      enabled             = false
      generateCertificate = false
      registerWebhook     = false
    }
  })]
}

resource "helm_release" "goldilocks" {
  depends_on = [helm_release.vpa_recommender]

  name       = "goldilocks"
  repository = "https://charts.fairwinds.com/stable"
  chart      = "goldilocks"
  namespace  = kubernetes_namespace_v1.goldilocks.metadata[0].name
  version    = "10.4.0"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    vpa            = { enabled = false }
    metrics-server = { enabled = false }

    controller = {
      resources = {
        requests = {
          cpu    = "25m"
          memory = "256Mi"
        }
      }
    }

    dashboard = {
      replicaCount = 1
      resources = {
        requests = {
          cpu    = "25m"
          memory = "256Mi"
        }
      }
      service = {
        type = "ClusterIP"
        port = 80
      }
      httpRoute = { enabled = false }
      ingress   = { enabled = false }
    }
  })]
}

resource "kubernetes_manifest" "goldilocks_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.goldilocks]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "goldilocks"
      namespace = kubernetes_namespace_v1.goldilocks.metadata[0].name
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = ["goldilocks.home.shdr.ch"]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "goldilocks-dashboard"
          port = 80
        }]
      }]
    }
  }
}
