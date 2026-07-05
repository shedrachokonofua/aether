# =============================================================================
# NVIDIA GPU Platform
# =============================================================================
# Device plugin (with time-slicing), dcgm-exporter, and RuntimeClass
# for Talos GPU nodes.

locals {
  nvidia_device_plugin_version = "v0.19.0"
  dcgm_exporter_version        = "4.8.1"

  gpu_node_selector = {
    "extensions.talos.dev/nvidia-container-toolkit-lts" = "580.105.08-v1.18.1"
  }
  gpu_neo_node_selector = merge(local.gpu_node_selector, {
    "kubernetes.io/hostname" = "talos-neo"
  })

  gpu_device_plugin_config_label = "nvidia.com/device-plugin.config"
  gpu_device_plugin_configs = {
    # Neo's Blackwell card has enough VRAM for broad opportunistic sharing.
    blackwell = 12
    # Smith's GTX 1660 Super is a 6GB Turing card. 3 slices so the game-server
    # Sunshine session can coexist with jellyfin transcode + immich-ml if they
    # reschedule onto smith. VRAM is tight at 6GB — fine for the actual library
    # (Football Manager + PS2/PS3 emulation), watch for OOM with heavier titles.
    turing = 3
  }
  gpu_node_device_plugin_configs = {
    talos-neo   = "blackwell"
    talos-smith = "turing"
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
# Advertises nvidia.com/gpu resources. Time-slicing is selected per node by
# nvidia.com/device-plugin.config so smaller GPUs do not get overpacked.

resource "kubernetes_labels" "gpu_device_plugin_config" {
  for_each = local.gpu_node_device_plugin_configs

  api_version = "v1"
  kind        = "Node"

  metadata {
    name = each.key
  }

  labels = {
    (local.gpu_device_plugin_config_label) = each.value
  }
}

resource "helm_release" "nvidia_device_plugin" {
  depends_on = [
    helm_release.cilium,
    kubernetes_labels.gpu_device_plugin_config,
    kubernetes_manifest.nvidia_runtime_class,
  ]

  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = module.namespace["gpu-system"].name
  version    = local.nvidia_device_plugin_version
  wait       = true
  timeout    = 300

  values = [yamlencode({
    config = {
      default = "blackwell"
      map = {
        for name, replicas in local.gpu_device_plugin_configs : name => yamlencode({
          version = "v1"
          sharing = {
            timeSlicing = {
              resources = [{
                name     = "nvidia.com/gpu"
                replicas = replicas
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
# Kyverno: disable the NVIDIA device-plugin XID health-check loop
# =============================================================================
# talos-smith's GPU is a GeForce GTX 1660 SUPER on the open kernel modules, which
# lack NVML XID event support. The device plugin's health-check goroutine then
# busy-spins on eventSet.Wait() (returns immediately, no sleep) and burns ~1.5 CPU
# cores continuously — while the datacenter Blackwell node (talos-neo) blocks
# properly and stays idle. The nvidia-device-plugin chart (v0.19.0) has no env
# passthrough, so inject DP_DISABLE_HEALTHCHECKS=xids into the plugin container at
# admission. Applies to all plugin pods: DaemonSet pods carry no spec.nodeName at
# CREATE (the scheduler binds the node later), so per-node scoping is not possible
# at the admission webhook. On talos-neo this trades XID auto-unhealthy detection
# for DCGM/dmesg-based GPU fault alerting, which is acceptable for this cluster.
resource "kubectl_manifest" "kyverno_nvidia_dp_disable_healthcheck_geforce" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "nvidia-dp-disable-healthcheck-geforce"
      annotations = {
        "pod-policies.kyverno.io/autogen-controllers" = "none"
        "policies.kyverno.io/title"                   = "Disable NVIDIA device-plugin XID health check on GeForce node"
        "policies.kyverno.io/category"                = "GPU"
        "policies.kyverno.io/subject"                 = "Pod"
        "policies.kyverno.io/description"             = "GeForce GTX 1660 SUPER + open kernel modules on talos-smith lack NVML XID event support, so the device-plugin health-check loop busy-spins (~1.5 cores). Injects DP_DISABLE_HEALTHCHECKS=xids into all nvidia-device-plugin pods (DaemonSet pods lack spec.nodeName at admission, so node scoping is not feasible); talos-neo relies on DCGM/dmesg for XID fault detection instead."
      }
    }
    spec = {
      background = false
      rules = [{
        name = "inject-dp-disable-healthchecks"
        match = {
          any = [{
            resources = {
              kinds      = ["Pod"]
              namespaces = ["gpu-system"]
              selector = {
                matchLabels = {
                  "app.kubernetes.io/name" = "nvidia-device-plugin"
                }
              }
            }
          }]
        }
        mutate = {
          patchStrategicMerge = {
            spec = {
              containers = [{
                name = "nvidia-device-plugin-ctr"
                env = [{
                  name  = "DP_DISABLE_HEALTHCHECKS"
                  value = "xids"
                }]
              }]
            }
          }
        }
      }]
    }
  })
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
  namespace  = module.namespace["gpu-system"].name
  version    = local.dcgm_exporter_version
  wait       = true
  timeout    = 300

  values = [yamlencode({
    runtimeClassName = "nvidia"
    nodeSelector     = local.gpu_node_selector

    serviceMonitor = { enabled = false }

    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { cpu = "500m", memory = "1Gi" }
    }
  })]
}
