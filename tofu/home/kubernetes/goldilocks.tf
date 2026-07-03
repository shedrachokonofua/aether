# =============================================================================
# Goldilocks + VPA Recommender
# =============================================================================
# Resource right-sizing advisor only. VPA updater and admission controller stay
# disabled so recommendations are reviewed and copied back into Tofu instead of
# mutating or evicting Pods at runtime.


resource "helm_release" "vpa_recommender" {
  depends_on = [
    module.namespace["goldilocks"],
    helm_release.metrics_server,
  ]

  name       = "vpa"
  repository = "https://charts.fairwinds.com/stable"
  chart      = "vpa"
  namespace  = module.namespace["goldilocks"].name
  version    = "4.12.0"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    metrics-server = { enabled = false }

    recommender = {
      enabled = true
      extraArgs = {
        storage                      = "prometheus"
        prometheus-address           = "https://prometheus.home.shdr.ch"
        prometheus-cadvisor-job-name = "otel-metrics"
        container-name-label         = "container"
        container-namespace-label    = "namespace"
        container-pod-name-label     = "pod"
        metric-for-pod-labels        = "kube_pod_labels{job=\"otel-metrics\",exported_job=\"kube-state-metrics\"}[8d]"
        pod-label-prefix             = "label_"
        pod-name-label               = "pod"
        pod-namespace-label          = "namespace"
        memory-saver                 = "true"
      }
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
  namespace  = module.namespace["goldilocks"].name
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
      namespace = module.namespace["goldilocks"].name
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
