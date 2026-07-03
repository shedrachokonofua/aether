# =============================================================================
# Namespace-derived workload priority classes
# =============================================================================

locals {
  aether_priority_classes = {
    platform = "aether-platform"
    app      = "aether-app"
    batch    = "aether-batch"
    sandbox  = "aether-sandbox"
  }

  # Platform keeps the pre-existing critical classes used by node agents and
  # node remediation. Lower tiers may only choose their derived class or lower.
  aether_allowed_priority_classes = {
    platform = [
      local.node_agent_priority_class,
      "system-cluster-critical",
      "system-node-critical",
      local.aether_priority_classes.platform,
      local.aether_priority_classes.app,
      local.aether_priority_classes.batch,
      local.aether_priority_classes.sandbox,
    ]
    app = [
      local.aether_priority_classes.app,
      local.aether_priority_classes.batch,
      local.aether_priority_classes.sandbox,
    ]
    batch = [
      local.aether_priority_classes.batch,
      local.aether_priority_classes.sandbox,
    ]
    sandbox = [
      local.aether_priority_classes.sandbox,
    ]
  }
}

resource "kubernetes_priority_class_v1" "aether_platform" {
  metadata {
    name = "aether-platform"
  }

  value             = 100000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Platform control-plane workloads that must run ahead of ordinary application pods."
}

resource "kubernetes_priority_class_v1" "aether_app" {
  metadata {
    name = "aether-app"
  }

  value             = 1000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Interactive application workloads owned by the homelab."
}

resource "kubernetes_priority_class_v1" "aether_batch" {
  metadata {
    name = "aether-batch"
  }

  value             = 100
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Autonomous agents, CI jobs, and other deferrable compute."
}

resource "kubernetes_priority_class_v1" "aether_sandbox" {
  metadata {
    name = "aether-sandbox"
  }

  value          = 0
  global_default = true
  # PreemptLowerPriority at value 0 preempts nothing in practice (no negative
  # classes exist), but unlike "Never" it doesn't make admission reject pods
  # that carry the k8s-default preemptionPolicy without a priorityClassName
  # (e.g. everything synced from a vcluster).
  preemption_policy = "PreemptLowerPriority"
  description       = "Default lowest-priority class for untrusted, guest, or unclassified workloads."
}
