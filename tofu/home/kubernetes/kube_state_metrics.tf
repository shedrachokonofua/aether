# =============================================================================
# kube-state-metrics — Kubernetes API object state as Prometheus metrics
# =============================================================================
# Complements kubeletstats (live usage) with declared/desired state from the
# API server: node capacity/allocatable, pod phases, deployment replicas,
# PVC binding, HPA targets, etc. Scraped by the cluster-mode otel-collector.

locals {
  kube_state_metrics_name          = "kube-state-metrics"
  kube_state_metrics_chart_version = "5.27.0"
  kube_state_metrics_port          = 8080
}

resource "helm_release" "kube_state_metrics" {
  depends_on = [helm_release.cilium]

  name       = local.kube_state_metrics_name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  namespace  = module.namespace["observability"].name
  version    = local.kube_state_metrics_chart_version
  wait       = true
  timeout    = 300

  values = [yamlencode({
    fullnameOverride = local.kube_state_metrics_name

    # Placement is left to the arch-labeler plus Kyverno.

    resources = {
      requests = { cpu = "20m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
    }

    extraArgs = [
      "--metric-labels-allowlist=namespaces=[aether.shdr.ch/tier,aether.shdr.ch/owner,aether.shdr.ch/backup,aether.shdr.ch/criticality,aether.shdr.ch/exposure]",
    ]
  })]
}
