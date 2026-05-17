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
  agent_sandbox_version    = "v0.4.5"
  agent_sandbox_controller = "agent-sandbox-system" # created by upstream manifest
  agent_sandbox_workloads  = "sandboxes"            # where Sandbox CRs live
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

resource "kubectl_manifest" "agent_sandbox_core" {
  for_each = data.kubectl_file_documents.agent_sandbox_core.manifests

  depends_on = [helm_release.cilium]

  yaml_body         = each.value
  server_side_apply = true
}

resource "kubectl_manifest" "agent_sandbox_extensions" {
  for_each = data.kubectl_file_documents.agent_sandbox_extensions.manifests

  # Extensions reference CRDs / RBAC defined by the core manifest.
  depends_on = [kubectl_manifest.agent_sandbox_core]

  yaml_body         = each.value
  server_side_apply = true
}

# =============================================================================
# RuntimeClass — kata
# =============================================================================
# The "kata" RuntimeClass is provisioned by mux.tf (kubernetes_manifest.
# mux_kata_runtime_class) — first consumer to land it owns the resource.
# Sandboxes opt in via runtimeClassName: kata.

# =============================================================================
# Workload namespace — sandboxes
# =============================================================================
# Where Sandbox CRs and their pods live. PodSecurity restricted by default;
# kata pods comply.

resource "kubernetes_namespace_v1" "sandboxes" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.agent_sandbox_workloads

    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/audit"           = "restricted"
    }
  }
}

# =============================================================================
# Default-deny NetworkPolicy
# =============================================================================
# All Sandbox pods start with no ingress and no egress except cluster DNS.
# Per-agent allow-lists land in Phase 2 (one NetworkPolicy per agent).

resource "kubernetes_network_policy_v1" "sandboxes_default_deny" {
  metadata {
    name      = "default-deny"
    namespace = kubernetes_namespace_v1.sandboxes.metadata[0].name
  }

  spec {
    pod_selector {} # all pods
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "sandboxes_allow_dns" {
  metadata {
    name      = "allow-dns"
    namespace = kubernetes_namespace_v1.sandboxes.metadata[0].name
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
# ResourceQuota — bound the sandbox namespace blast radius
# =============================================================================
# Sized for ~2-4 active sandboxes. Bump when you grow.

resource "kubernetes_resource_quota_v1" "sandboxes" {
  metadata {
    name      = "sandboxes-quota"
    namespace = kubernetes_namespace_v1.sandboxes.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"           = "8"
      "requests.memory"        = "16Gi"
      "limits.cpu"             = "16"
      "limits.memory"          = "32Gi"
      "requests.storage"       = "200Gi"
      "persistentvolumeclaims" = "10"
      "pods"                   = "20"
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
    namespace = kubernetes_namespace_v1.sandboxes.metadata[0].name
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
