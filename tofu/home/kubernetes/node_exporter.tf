# =============================================================================
# Prometheus node-exporter — cluster-wide
# =============================================================================
# Standard host metrics (CPU, disk, net, conntrack) plus thermal_zone/hwmon for
# Pi temperature + undervoltage. Scraped by the cluster otel-collector and
# shipped to https://otel.home.shdr.ch.

locals {
  node_exporter_name          = "node-exporter"
  node_exporter_chart_version = "4.46.1"
  node_exporter_port          = 9100
}

resource "helm_release" "node_exporter" {
  depends_on = [helm_release.cilium]

  name       = local.node_exporter_name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-node-exporter"
  namespace  = kubernetes_namespace_v1.system.metadata[0].name
  version    = local.node_exporter_chart_version
  wait       = true
  timeout    = 300

  values = [yamlencode({
    fullnameOverride = local.node_exporter_name

    service = {
      port       = local.node_exporter_port
      targetPort = local.node_exporter_port
      portName   = "metrics"
    }

    # Tolerate control-plane taint so we get metrics from every node.
    tolerations = [
      { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" },
      { key = "node-role.kubernetes.io/master", operator = "Exists", effect = "NoSchedule" },
    ]

    resources = {
      requests = { cpu = "1m", memory = "1Mi" }
      limits   = { cpu = "100m", memory = "64Mi" }
    }
  })]
}
