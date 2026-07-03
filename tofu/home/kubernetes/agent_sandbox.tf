# =============================================================================
# Agent Sandbox — platform layer for AI agent workspaces
# =============================================================================
# Installs the kubernetes-sigs/agent-sandbox controller (Sandbox + extensions
# CRDs) and prepares a `sandboxes` workload namespace with default policies.
#
# Phase 1 (this file): controller, namespace, RuntimeClass, default policies.
#                      No agent consumes this yet.
# Phase 2 (agent_shell.tf, future):
#                      SandboxTemplates + Sandbox CRs for tungsten / beryl,
#                      egress allow-lists, hermes ssh-backend rewiring.
#
# Runtime: kata-containers via Talos system extension (see cloud_images.tf).
# Sandboxes pin to amd64 (Pi nodes excluded — Cloud Hypervisor needs GICv3).

locals {
  agent_sandbox_version                  = "v0.4.5"
  agent_sandbox_controller               = "agent-sandbox-system" # created by upstream manifest
  agent_sandbox_workloads                = "sandboxes"            # where Sandbox CRs live
  agent_sandbox_controller_deployment_id = "/apis/apps/v1/namespaces/${local.agent_sandbox_controller}/deployments/agent-sandbox-controller"
}

# =============================================================================
# Upstream manifests (controller + CRDs + extensions)
# =============================================================================
# Fetched at apply time from the pinned release. Versioned by
# local.agent_sandbox_version; bump to upgrade.

data "http" "agent_sandbox_core_manifest" {
  url = "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${local.agent_sandbox_version}/manifest.yaml"
}

data "http" "agent_sandbox_extensions_manifest" {
  url = "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${local.agent_sandbox_version}/extensions.yaml"
}

data "kubectl_file_documents" "agent_sandbox_core" {
  content = data.http.agent_sandbox_core_manifest.response_body
}

data "kubectl_file_documents" "agent_sandbox_extensions" {
  content = data.http.agent_sandbox_extensions_manifest.response_body
}

locals {
  agent_sandbox_controller_resources = {
    requests = {
      cpu    = "50m"
      memory = "64Mi"
    }
    limits = {
      cpu    = "500m"
      memory = "256Mi"
    }
  }

  agent_sandbox_extensions_manifests = {
    for id, manifest in data.kubectl_file_documents.agent_sandbox_extensions.manifests :
    id => id == local.agent_sandbox_controller_deployment_id ? yamlencode(merge(
      yamldecode(manifest),
      {
        spec = merge(yamldecode(manifest).spec, {
          template = merge(yamldecode(manifest).spec.template, {
            spec = merge(yamldecode(manifest).spec.template.spec, {
              nodeSelector = merge(
                try(yamldecode(manifest).spec.template.spec.nodeSelector, {}),
                { "kubernetes.io/arch" = "amd64" }
              )
              containers = [
                for container in yamldecode(manifest).spec.template.spec.containers :
                merge(container, {
                  resources = container.name == "agent-sandbox-controller" ? local.agent_sandbox_controller_resources : try(container.resources, {})
                })
              ]
            })
          })
        })
      }
    )) : manifest
  }
}

resource "kubectl_manifest" "agent_sandbox_core" {
  # extensions.yaml ships the controller Deployment with the --extensions flag;
  # keep that object under one kubectl_manifest address to avoid SSA drift loops.
  for_each = {
    for id, manifest in data.kubectl_file_documents.agent_sandbox_core.manifests : id => manifest
    if id != local.agent_sandbox_controller_deployment_id
  }

  depends_on = [helm_release.cilium]

  yaml_body         = each.value
  server_side_apply = true
}

resource "kubectl_manifest" "agent_sandbox_extensions" {
  for_each = local.agent_sandbox_extensions_manifests

  # Extensions reference CRDs / RBAC defined by the core manifest.
  depends_on = [kubectl_manifest.agent_sandbox_core]

  yaml_body         = each.value
  server_side_apply = true
}

# =============================================================================
# RuntimeClass — kata
# =============================================================================
# The "kata" RuntimeClass is provisioned as a platform-owned runtime class in
# runtime_classes.tf. Sandboxes opt in via runtimeClassName: kata.

# =============================================================================
# Workload namespace — sandboxes
# =============================================================================
# Where Sandbox CRs and their pods live. PodSecurity restricted by default;
# kata pods comply.


# =============================================================================
# Default-deny NetworkPolicy
# =============================================================================
# All Sandbox pods start with no ingress and no egress except cluster DNS.
# Per-agent allow-lists land in Phase 2 (one NetworkPolicy per agent).

resource "kubernetes_network_policy_v1" "sandboxes_default_deny" {
  metadata {
    name      = "default-deny"
    namespace = module.namespace["sandboxes"].name
  }

  spec {
    pod_selector {} # all pods
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "sandboxes_allow_dns" {
  metadata {
    name      = "allow-dns"
    namespace = module.namespace["sandboxes"].name
  }

  spec {
    pod_selector {} # all pods

    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
  }
}


# =============================================================================
# LimitRange — default + max container resources
# =============================================================================
# Without explicit container limits, Sandbox pods get sensible defaults.
# Ceiling prevents a single sandbox from consuming the whole quota.

resource "kubernetes_limit_range_v1" "sandboxes" {
  metadata {
    name      = "sandboxes-limits"
    namespace = module.namespace["sandboxes"].name
  }

  spec {
    limit {
      type = "Container"

      default = {
        cpu    = "1"
        memory = "1Gi"
      }

      default_request = {
        cpu    = "100m"
        memory = "256Mi"
      }

      max = {
        cpu    = "4"
        memory = "8Gi"
      }
    }
  }
}
