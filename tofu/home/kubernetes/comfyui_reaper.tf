# =============================================================================
# aether-comfyui-reaper
# =============================================================================
# Wasm component that flushes idle GPU-resident model state from ComfyUI.
# Cron-triggered; queries Prometheus for per-target idle time and, past
# threshold, calls ComfyUI's /free. Deployed as a wasmCloud WorkloadDeployment
# (operator schedules it onto the shared host pods; the selector-less Service
# gets an operator-managed EndpointSlice).
#
# Artifact vs deploy ownership:
#   - The .wasm is built + published as an OCI artifact by the
#     aether-comfyui-reaper repo CI (so/aether/aether-comfyui-reaper).
#   - Deployment is owned here — wasmcloud-system is platform-tier, aether-owned.
#
# Rollout: pin the tag, bump + `tofu apply`, rollback = revert. (Keel can't
# watch this CRD; components are low-churn, so no auto-roller.)
#
# PREREQUISITE: the renamed project's registry path is empty until its first
# main pipeline publishes. Set the tag below to the published short SHA, apply.
#
# Component config lives under components[].localResources — NOT a top-level
# env list (that field is pruned by the CRD). allowedHosts is the capability
# egress allowlist; without it the outbound Prometheus/ComfyUI calls are denied
# and the reaper is a no-op.

locals {
  comfyui_reaper_name = "aether-comfyui-reaper"
  # Pinned by digest: bootstrap build carrying the GPU-utilization idle check.
  # (Same-tag + IfNotPresent won't re-pull; digest forces the operator to fetch
  # this exact build. Repin to a CI-published :sha once the repo is pushed.)
  comfyui_reaper_image = "${local.wasmcloud_registry_host}/so/aether/aether-comfyui-reaper@sha256:85f235825415d9df802487ccb8a30e15ab4e8181aacff21f9252f16ceb375444"

  comfyui_reaper_labels = {
    "app.kubernetes.io/name"       = "aether-comfyui-reaper"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
}

resource "kubectl_manifest" "comfyui_reaper_service" {
  depends_on = [helm_release.wasmcloud]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.comfyui_reaper_name
      namespace = "wasmcloud-system"
      labels    = local.comfyui_reaper_labels
    }
    spec = {
      type = "ClusterIP"
      # No selector — the operator manages the EndpointSlice from
      # spec.kubernetes.service on the WorkloadDeployment.
      ports = [{ name = "http", port = 80, protocol = "TCP" }]
    }
  })
}

resource "kubectl_manifest" "comfyui_reaper_workload" {
  depends_on = [
    helm_release.wasmcloud,
    kubernetes_secret_v1.wasmcloud_gitlab_registry,
    kubectl_manifest.comfyui_reaper_service,
  ]

  yaml_body = yamlencode({
    apiVersion = "runtime.wasmcloud.dev/v1alpha1"
    kind       = "WorkloadDeployment"
    metadata = {
      name      = local.comfyui_reaper_name
      namespace = "wasmcloud-system"
      labels    = local.comfyui_reaper_labels
    }
    spec = {
      replicas     = 1
      deployPolicy = "RollingUpdate"
      kubernetes   = { service = { name = local.comfyui_reaper_name } }
      template = {
        spec = {
          components = [{
            name  = local.comfyui_reaper_name
            image = local.comfyui_reaper_image
            # Always: the wasmCloud host caches components, so IfNotPresent
            # serves stale code on a digest bump (needs a manual host restart).
            imagePullPolicy = "Always"
            imagePullSecret = { name = "gitlab-registry" }
            localResources = {
              # Egress allowlist for wasi:http outgoing-handler. PROMETHEUS_URL
              # is a genuine external call (Prometheus is on the monitoring VM,
              # not in-cluster), not a convertible hairpin.
              allowedHosts = [
                "prometheus.home.shdr.ch",
                "comfyui.ai-serving.svc.cluster.local",
              ]
              environment = {
                config = {
                  COMFYUI_URL            = "http://comfyui.ai-serving.svc.cluster.local:8188"
                  PROMETHEUS_URL         = "https://prometheus.home.shdr.ch"
                  IDLE_THRESHOLD_SECONDS = "1800"
                }
              }
            }
          }]
          # incoming-handler (HTTP entrypoint) + outgoing-handler (Prometheus/
          # ComfyUI calls). wasi:cli/environment is host-native — NOT declared
          # here (declaring it makes the operator seek a nonexistent plugin and
          # fail the workload); env values arrive via localResources.environment.
          hostInterfaces = [
            {
              namespace  = "wasi"
              package    = "http"
              interfaces = ["incoming-handler"]
              config     = { host = local.comfyui_reaper_name }
            },
            { namespace = "wasi", package = "http", interfaces = ["outgoing-handler"] },
          ]
        }
      }
    }
  })
}

# Wake-up cadence; the component decides per-target whether to flush.
resource "kubectl_manifest" "comfyui_reaper_cron" {
  depends_on = [kubectl_manifest.comfyui_reaper_workload]

  yaml_body = yamlencode({
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata = {
      name      = "${local.comfyui_reaper_name}-tick"
      namespace = "wasmcloud-system"
      labels    = local.comfyui_reaper_labels
    }
    spec = {
      schedule                   = "*/10 * * * *"
      concurrencyPolicy          = "Forbid"
      successfulJobsHistoryLimit = 1
      failedJobsHistoryLimit     = 3
      jobTemplate = {
        spec = {
          backoffLimit            = 0
          ttlSecondsAfterFinished = 300
          template = {
            spec = {
              restartPolicy = "Never"
              # PSA restricted-clean so this survives the namespace-strategy PSA ratchet.
              securityContext = {
                runAsNonRoot   = true
                runAsUser      = 65534
                seccompProfile = { type = "RuntimeDefault" }
              }
              containers = [{
                # Docker Hub image, pulled via the cloned dockerhub-creds secret.
                name  = "trigger"
                image = "curlimages/curl:8.10.1"
                command = ["sh", "-c", <<-EOT
                  set -eu
                  echo "tick $(date -u +%FT%TZ)"
                  resp=$(curl -fsS -m 60 -X POST http://${local.comfyui_reaper_name}/)
                  echo "response: $resp"
                EOT
                ]
                securityContext = {
                  allowPrivilegeEscalation = false
                  readOnlyRootFilesystem   = true
                  capabilities             = { drop = ["ALL"] }
                }
                resources = {
                  requests = { cpu = "10m", memory = "16Mi" }
                  limits   = { cpu = "100m", memory = "64Mi" }
                }
              }]
            }
          }
        }
      }
    }
  })
}
