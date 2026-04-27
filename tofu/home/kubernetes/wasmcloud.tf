# =============================================================================
# wasmCloud v2 Runtime Operator
# =============================================================================
# K8s-native WebAssembly runtime. The chart installs:
#   - operator         (CRD reconciler for WorkloadDeployment / Artifact / Host)
#   - NATS             (intra-cluster scheduler + data-plane coordination only;
#                       not the v1 user-facing lattice — that model is retired)
#   - hostGroup-*      (Deployment per hostGroup, one wasmCloud host per replica)
#
# CRDs installed (group: runtime.wasmcloud.dev / v1alpha1):
#   Artifact, Host, Workload, WorkloadReplicaSet, WorkloadDeployment
#
# Notes:
#   - Istio Ambient handles mTLS, so global.tls.enabled is disabled (the chart
#     would otherwise generate self-signed certs for NATS).
#   - The deprecated runtime-gateway is disabled (operator now manages
#     EndpointSlices for WorkloadDeployments via spec.kubernetes.service).
#   - Pi-only host placement is NOT enforced here. The chart doesn't expose
#     nodeSelector/affinity on hostGroups, so once the Pi nodes join we add a
#     Kyverno mutate policy (see kyverno.tf) targeting Deployments named
#     `hostgroup-*` in `wasmcloud-system`. Until then, hosts schedule freely.

resource "helm_release" "wasmcloud" {
  depends_on = [helm_release.cilium]

  name             = "wasmcloud"
  repository       = "oci://ghcr.io/wasmcloud/charts"
  chart            = "runtime-operator"
  namespace        = "wasmcloud-system"
  create_namespace = true
  version          = "2.0.5"
  wait             = true
  timeout          = 600

  values = [yamlencode({
    # Service mesh handles mTLS; disable the chart's self-signed NATS certs.
    global = {
      tls          = { enabled = false }
      certificates = { generate = false }
      image = {
        pullSecrets = [{ name = "gitlab-registry" }]
      }
    }

    # Deprecated since 2.0.3 — operator routes via EndpointSlices instead.
    gateway = {
      enabled = false
    }

    # Two host pods for fault tolerance. Hosts are tiny (64Mi request, 512Mi
    # limit) and each can run hundreds of I/O-bound component instances, so
    # capacity isn't the constraint — only HA matters. arm-pool preference
    # comes from the existing aether-k8s-arch-labeler + arm-pool-guardrails
    # chain (multi-arch host images qualify automatically).
    runtime = {
      hostGroups = [{
        name     = "default"
        replicas = 2
        service = {
          type = "ClusterIP"
        }
        http = {
          enabled = true
          port    = 9191
          tls     = { enabled = false }
        }
        webgpu = { enabled = false }
        wasip3 = { enabled = false }
        resources = {
          requests = { cpu = "250m", memory = "64Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }]
    }
  })]
}

# =============================================================================
# imagePullSecret for the home GitLab Container Registry
# =============================================================================
# WorkloadDeployments reference Wasm components stored in the private home
# GitLab Container Registry; the wasmCloud host pods pull those components
# using this secret. Referenced by name "gitlab-registry" from each
# WorkloadDeployment's spec.template.spec.components[].imagePullSecret, and
# also wired into the chart's global.image.pullSecrets so the operator and
# host images themselves can be pulled from a mirror if ever needed.
#
# Currently uses the GitLab root account. Migrate to a scoped GitLab deploy
# token with `read_registry` scope once one is provisioned.

locals {
  wasmcloud_registry_host     = "registry.gitlab.home.shdr.ch"
  wasmcloud_registry_user     = var.secrets["gitlab.root_email"]
  wasmcloud_registry_password = var.secrets["gitlab.root_password"]
}

resource "kubernetes_secret_v1" "wasmcloud_gitlab_registry" {
  depends_on = [helm_release.wasmcloud]

  metadata {
    name      = "gitlab-registry"
    namespace = "wasmcloud-system"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.wasmcloud_registry_host) = {
          username = local.wasmcloud_registry_user
          password = local.wasmcloud_registry_password
          auth     = base64encode("${local.wasmcloud_registry_user}:${local.wasmcloud_registry_password}")
        }
      }
    })
  }
}
