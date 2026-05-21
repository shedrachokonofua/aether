# =============================================================================
# Kubernetes Descheduler
# =============================================================================
# Periodically nudges stateless Pods off over-requested ARM nodes. It does not
# pin workloads; it evicts eligible Pods and lets the default scheduler choose
# the replacement placement.

resource "kubernetes_namespace_v1" "descheduler" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "descheduler"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "helm_release" "descheduler" {
  depends_on = [kubernetes_namespace_v1.descheduler]

  name       = "descheduler"
  repository = "https://kubernetes-sigs.github.io/descheduler"
  chart      = "descheduler"
  version    = "0.35.1"
  namespace  = kubernetes_namespace_v1.descheduler.metadata[0].name
  wait       = true
  timeout    = 300

  values = [yamlencode({
    kind     = "CronJob"
    schedule = "*/15 * * * *"
    suspend  = true

    successfulJobsHistoryLimit = 3
    failedJobsHistoryLimit     = 3
    ttlSecondsAfterFinished    = 1800

    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
      limits = {
        cpu    = "500m"
        memory = "256Mi"
      }
    }

    podSecurityContext = {
      seccompProfile = {
        type = "RuntimeDefault"
      }
    }

    # Keep the descheduler itself off the constrained ARM pool.
    nodeSelector = {
      "kubernetes.io/arch" = "amd64"
    }

    deschedulerPolicy = {
      # Only evaluate the constrained ARM pool. Evicted Pods are recreated by
      # their controllers and placed by the default scheduler without app pins.
      nodeSelector = "aether.sh/node-pool=arm"

      maxNoOfPodsToEvictPerNode      = 2
      maxNoOfPodsToEvictPerNamespace = 2

      profiles = [{
        name = "arm-pool-balance"
        pluginConfig = [
          {
            name = "DefaultEvictor"
            args = {
              podProtections = {
                extraEnabled = [
                  "PodsWithPVC",
                ]
              }
            }
          },
          {
            name = "LowNodeUtilization"
            args = {
              thresholds = {
                cpu    = 50
                memory = 75
                pods   = 50
              }
              targetThresholds = {
                cpu    = 85
                memory = 85
                pods   = 85
              }
              numberOfNodes = 1
            }
          },
        ]
        plugins = {
          balance = {
            enabled = ["LowNodeUtilization"]
          }
        }
      }]
    }
  })]
}
