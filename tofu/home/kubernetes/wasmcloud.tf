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
  depends_on = [helm_release.cilium, module.namespace["pop"], kubernetes_secret_v1.pop_gitlab_registry]

  name             = "wasmcloud"
  repository       = "oci://ghcr.io/wasmcloud/charts"
  chart            = "runtime-operator"
  namespace        = "wasmcloud-system"
  create_namespace = false
  version          = "2.10.3"
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

    # Two host pods for fault tolerance. Host memory is mostly what the
    # components cost: 2.5.2 hosts sat near 400Mi, so a 512Mi limit left ~90Mi
    # and deploying a 13MB jco (StarlingMonkey) component OOM-killed a default
    # host; 2.10.3 hosts idle at 7–32Mi. The limit is also the host's
    # guest-memory ceiling since 2.9 (WASH_HOST_MAX_GUEST_MEMORY).
    # arm-pool preference comes from the existing aether-k8s-arch-labeler +
    # arm-pool-guardrails chain (multi-arch host images qualify automatically).
    runtime = {
      hostGroups = [
        {
          name      = "default"
          namespace = "wasmcloud-system"
          replicas  = 2
          service   = { type = "ClusterIP" }
          http      = { enabled = true, port = 9191, tls = { enabled = false } }
          webgpu    = { enabled = false }
          wasip3    = { enabled = false }
          resources = {
            requests = { cpu = "250m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "1Gi" }
          }
        },
        {
          name      = "pop"
          namespace = "pop"
          replicas  = 2
          service   = { type = "ClusterIP" }
          http      = { enabled = true, port = 9191, tls = { enabled = false } }
          webgpu    = { enabled = false }
          wasip3    = { enabled = false }
          resources = {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "2Gi" }
          }
          # No --enable-meters: on wash 2.5.2 its fuel metering made every
          # pop function (wstd Rust and jco TS alike) fail with HTTP 500
          # ("oneshot channel closed but no response was sent"); reproduced
          # locally with `wash dev --enable-meters` against the same component.
          extraArgs = ["--wasi-otel"]
          # Host and wasi-otel plugin telemetry go to the collector's gRPC port
          # (pop-api/pop-origin use OTLP/HTTP on 4318). Since 2.10 the host's
          # OTel init follows the env spec, whose default protocol is
          # http/protobuf, so gRPC is pinned explicitly.
          env = [
            { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = local.pop_otel_grpc_endpoint },
            { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "grpc" },
            { name = "OTEL_RESOURCE_ATTRIBUTES", value = "service.namespace=pop,deployment.environment=home" },
          ]
        },
        # molecule spike: wasm agents with a shell (brush) and files. Kept off
        # `default` so a heavy agent component cannot OOM the aether
        # components' hosts; workloads opt in with hostSelector
        # { hostgroup = "daimyo" } (canary and reaper pin `default`). The
        # workspace volume is what components preopen as their working tree.
        {
          name      = "daimyo"
          namespace = "wasmcloud-system"
          replicas  = 1
          service   = { type = "ClusterIP" }
          http      = { enabled = true, port = 9191, tls = { enabled = false } }
          webgpu    = { enabled = false }
          wasip3    = { enabled = false }
          resources = {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
          volumes      = [{ name = "workspace", emptyDir = { sizeLimit = "2Gi" } }]
          volumeMounts = [{ name = "workspace", mountPath = "/var/molecule/workspace" }]
        },
      ]
    }

    operator = {
      hostNamespaces   = ["wasmcloud-system", "pop"]
      allowSharedHosts = false
    }
  })]
}

locals {
  pop_registry_host = "registry.gitlab.home.shdr.ch"
}

# Credential-less: the chart's global.image.pullSecrets names `gitlab-registry`
# for every host group, so the pop host pods expect one in namespace `pop`.
# Function workloads carry no imagePullSecret (so/pop-functions is public, and
# the host would turn even this empty secret into failing Basic auth); the
# push/delete token is pop-api's alone (pop.tf, OpenBao pop/registry-token).
resource "kubernetes_secret_v1" "pop_gitlab_registry" {
  depends_on = [module.namespace["pop"]]
  metadata {
    name      = "gitlab-registry"
    namespace = module.namespace["pop"].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({ auths = {} })
  }
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
