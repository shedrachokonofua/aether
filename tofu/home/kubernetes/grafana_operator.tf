# Shared controller for application-owned Grafana resources. Applications render
# GrafanaDashboard and GrafanaAlertRuleGroup CRs from their own Helm charts.
locals {
  grafana_operator_chart_version = "5.24.0"
}

resource "helm_release" "grafana_operator" {
  depends_on = [module.namespace["observability"]]

  name       = "grafana-operator"
  repository = "oci://ghcr.io/grafana/helm-charts"
  chart      = "grafana-operator"
  namespace  = module.namespace["observability"].name
  version    = local.grafana_operator_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    crds = { immutable = true }
    enforceCacheLabels = "safe"
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }
  })]
}
