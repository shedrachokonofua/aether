# =============================================================================
# aether-wasm-hello
# =============================================================================
# Canary Wasm component exercising the wasmCloud runtime end to end (incoming
# HTTP handler, exposed via the internal gateway). Artifact built + published by
# the aether-wasm-hello repo CI (so/aether-wasm-hello); deployment owned here.
#
# Migrated off the guest channel: previously self-deployed via its own repo CI
# (kubectl into wasmcloud-system). wasmcloud-system is platform-tier and
# aether-owned, so the deployer now owns the namespace.
#
# ADOPTION (first apply only): the live Service / WorkloadDeployment / HTTPRoute
# were created by the old CI (labels app.kubernetes.io/managed-by: gitlab-ci).
# tofu must take them over rather than recreate — import each:
#   tofu import 'module.home.module.kubernetes.kubectl_manifest.aether_wasm_hello_workload' \
#     wasmcloud-system/aether-wasm-hello   # (repeat for service + route)
# or delete the three live objects first (operator recreates the workload;
# brief blip on a hello-world). Import is cleaner.
#
# The HTTPRoute rewrites the external hostname to the incoming-handler's
# registered host (the component name) — the wasm host router matches on that.

locals {
  aether_wasm_hello_name = "aether-wasm-hello"
  # Digest pin: welcome-page build (repo commit 5afdfd8b). Digest forces the
  # cache-holding host to fetch this exact build; repin on each release.
  aether_wasm_hello_image = "${local.wasmcloud_registry_host}/so/aether-wasm-hello@sha256:2efcd8ac24912ed639e199f4599d96c3df1d61158e3aeaf6132bf725407d6e0b"

  aether_wasm_hello_labels = {
    "app.kubernetes.io/name"       = "aether-wasm-hello"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
}

resource "kubectl_manifest" "aether_wasm_hello_service" {
  depends_on = [helm_release.wasmcloud]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.aether_wasm_hello_name
      namespace = "wasmcloud-system"
      labels    = local.aether_wasm_hello_labels
    }
    spec = {
      type  = "ClusterIP"
      ports = [{ name = "http", port = 80, protocol = "TCP" }]
    }
  })
}

resource "kubectl_manifest" "aether_wasm_hello_workload" {
  depends_on = [
    helm_release.wasmcloud,
    kubernetes_secret_v1.wasmcloud_gitlab_registry,
    kubectl_manifest.aether_wasm_hello_service,
  ]

  yaml_body = yamlencode({
    apiVersion = "runtime.wasmcloud.dev/v1alpha1"
    kind       = "WorkloadDeployment"
    metadata = {
      name      = local.aether_wasm_hello_name
      namespace = "wasmcloud-system"
      labels    = local.aether_wasm_hello_labels
    }
    spec = {
      replicas     = 3
      deployPolicy = "RollingUpdate"
      kubernetes   = { service = { name = local.aether_wasm_hello_name } }
      template = {
        spec = {
          # Hello-world: incoming handler only — no egress, no env.
          components = [{
            name            = local.aether_wasm_hello_name
            image           = local.aether_wasm_hello_image
            imagePullPolicy = "Always"
            imagePullSecret = { name = "gitlab-registry" }
          }]
          hostInterfaces = [{
            namespace  = "wasi"
            package    = "http"
            interfaces = ["incoming-handler"]
            config     = { host = local.aether_wasm_hello_name }
          }]
        }
      }
    }
  })
}

resource "kubectl_manifest" "aether_wasm_hello_route" {
  depends_on = [kubectl_manifest.aether_wasm_hello_service]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = local.aether_wasm_hello_name
      namespace = "wasmcloud-system"
      labels    = local.aether_wasm_hello_labels
    }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default", sectionName = "http" }]
      # Must stay within the wasmcloud-system `hostnames` contract annotation
      # (namespace_contracts.tf).
      hostnames = ["hello-wasm.home.shdr.ch"]
      rules = [{
        matches = [{ path = { type = "PathPrefix", value = "/" } }]
        filters = [{
          type       = "URLRewrite"
          urlRewrite = { hostname = local.aether_wasm_hello_name }
        }]
        backendRefs = [{ name = local.aether_wasm_hello_name, port = 80 }]
      }]
    }
  })
}
