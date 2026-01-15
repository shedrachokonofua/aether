# =============================================================================
# Metrics Server
# =============================================================================
# Provides resource metrics API (metrics.k8s.io) for:
#   - kubectl top nodes/pods
#   - Headlamp resource utilization
#   - Horizontal Pod Autoscaler (HPA)
#   - Vertical Pod Autoscaler (VPA)

resource "helm_release" "metrics_server" {
  depends_on = [helm_release.cilium]

  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  namespace        = "kube-system"
  version          = "3.12.2"
  wait             = true
  timeout          = 300

  values = [yamlencode({
    args = [
      # Talos uses self-signed kubelet certificates
      "--kubelet-insecure-tls",
      # Prefer internal IP for kubelet connection (faster, more reliable)
      "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"
    ]

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "128Mi" }
    }

    # Run on control plane nodes for reliability
    tolerations = [{
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }]

    # High availability for production
    replicas = 2

    podDisruptionBudget = {
      enabled      = true
      minAvailable = 1
    }

    # Metrics for self-monitoring
    metrics = {
      enabled = true
    }
  })]
}

