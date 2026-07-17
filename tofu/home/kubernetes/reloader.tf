# =============================================================================
# Reloader — restart workloads when referenced Secrets/ConfigMaps rotate
# =============================================================================

locals {
  reloader_chart_version = "2.2.12"
}

resource "helm_release" "reloader" {
  depends_on = [
    helm_release.cilium,
    module.namespace["system"],
  ]

  name       = "reloader"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  namespace  = module.namespace["system"].name
  version    = local.reloader_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    reloader = {
      watchGlobally = true
      deployment = {
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { cpu = "250m", memory = "256Mi" }
        }
      }
    }
  })]
}
