# =============================================================================
# NVIDIA GPU Platform
# =============================================================================
# Device plugin (with time-slicing), dcgm-exporter, and RuntimeClass
# for talos-neo GPU node.

locals {
  nvidia_device_plugin_version = "v0.19.0"
  dcgm_exporter_version        = "4.8.1"

  gpu_node_selector = {
    "extensions.talos.dev/nvidia-container-toolkit-lts" = "580.105.08-v1.18.1"
  }
}

# =============================================================================
# RuntimeClass — nvidia
# =============================================================================
# Talos nvidia-container-toolkit extension registers the "nvidia" handler
# in containerd. Workloads requesting GPU resources reference this class.

resource "kubernetes_manifest" "nvidia_runtime_class" {
  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name = "nvidia"
    }
    handler = "nvidia"
  }
}

# =============================================================================
# NVIDIA Device Plugin
# =============================================================================
# Advertises nvidia.com/gpu resources. Time-slicing configured for 8 replicas
# so multiple pods can share the single physical GPU concurrently.

resource "helm_release" "nvidia_device_plugin" {
  depends_on = [helm_release.cilium, kubernetes_manifest.nvidia_runtime_class]

  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = kubernetes_namespace_v1.system.metadata[0].name
  version    = local.nvidia_device_plugin_version
  wait       = true
  timeout    = 300

  values = [yamlencode({
    config = {
      default = "default"
      map = {
        default = yamlencode({
          version = "v1"
          sharing = {
            timeSlicing = {
              resources = [{
                name     = "nvidia.com/gpu"
                replicas = 8
              }]
            }
          }
        })
      }
    }

    runtimeClassName = "nvidia"

    gfd = { enabled = false }
    nfd = { enabled = false }

    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "extensions.talos.dev/nvidia-container-toolkit-lts"
              operator = "Exists"
            }]
          }]
        }
      }
    }
  })]
}

# =============================================================================
# DCGM Exporter — GPU Metrics
# =============================================================================
# DaemonSet on GPU nodes, exposes Prometheus metrics on port 9400.
# Scraped by the OTEL Deployment collector.

resource "helm_release" "dcgm_exporter" {
  depends_on = [helm_release.nvidia_device_plugin]

  name       = "dcgm-exporter"
  repository = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart      = "dcgm-exporter"
  namespace  = kubernetes_namespace_v1.system.metadata[0].name
  version    = local.dcgm_exporter_version
  wait       = true
  timeout    = 300

  values = [yamlencode({
    runtimeClassName = "nvidia"
    nodeSelector     = local.gpu_node_selector

    serviceMonitor = { enabled = false }

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "256Mi" }
    }
  })]
}