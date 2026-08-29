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
  namespace  = module.namespace["observability"].name
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

    # 30d: ARM-pool p95 25Mi, fleet max 39Mi, ARM-pool CPU p50 17m.
    # No CPU limit: 100m throttled 64-78% of CFS periods; 500m cut to 0-23% (22-23% on Pi 4-class workers); scrape-driven work cannot run away (CPU p95 25m, 100ms periods).
    resources = {
      requests = { cpu = "20m", memory = "32Mi" }
      limits   = { memory = "64Mi" }
    }
  })]
}
