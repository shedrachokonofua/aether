locals {
  contract_labels = {
    "aether.shdr.ch/tier"     = var.tier
    "aether.shdr.ch/owner"    = var.owner
    "aether.shdr.ch/backup"   = var.backup
    "aether.shdr.ch/exposure" = var.exposure
  }


  criticality_tier_defaults = {
    platform     = "high"
    app          = "normal"
    agent        = "normal"
    tenant       = "normal"
    sandbox      = "low"
    guest        = "low"
    unclassified = "low"
  }
  optional_label_defaults = {
    egress          = var.egress
    arch            = var.arch
    criticality     = coalesce(var.criticality, local.criticality_tier_defaults[var.tier])
    lifecycle       = var.ns_lifecycle
    registry_access = var.registry_access
    runtime         = var.runtime
    mesh            = var.mesh
  }

  optional_labels = {
    for key, value in local.optional_label_defaults :
    "aether.shdr.ch/${replace(key, "_", "-")}" => value
    if value != null && value != ""
  }

  psa_signal_labels = {
    "pod-security.kubernetes.io/audit" = "restricted"
    "pod-security.kubernetes.io/warn"  = "restricted"
  }

  psa_enforce_defaults = {
    platform     = null
    app          = "baseline"
    agent        = "restricted"
    sandbox      = "restricted"
    guest        = "baseline"
    tenant       = "baseline"
    unclassified = "baseline"
  }

  derived_labels = {
    "aether.shdr.ch/gateway-access"        = contains(["internal", "public"], var.exposure) ? "internal" : "none"
    "aether.shdr.ch/gateway-access-public" = var.exposure == "public" ? "true" : null
    "goldilocks.fairwinds.com/enabled"     = contains(["app", "agent", "guest"], var.tier) ? "true" : "false"
    "istio.io/dataplane-mode"              = coalesce(var.mesh, "none")
    "pod-security.kubernetes.io/enforce"   = local.psa_enforce_defaults[var.tier]
  }

  derived_non_null_labels = {
    for key, value in local.derived_labels : key => value
    if value != null && value != ""
  }

  contract_annotations = merge(
    var.description != "" ? { "aether.shdr.ch/description" = var.description } : {},
    var.source_file != "" ? { "aether.shdr.ch/source" = var.source_file } : {},
    length(var.hostnames) > 0 ? { "aether.shdr.ch/hostnames" = join(",", var.hostnames) } : {},
    var.extra_annotations,
  )
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.name
    labels = merge(
      local.contract_labels,
      local.optional_labels,
      local.psa_signal_labels,
      local.derived_non_null_labels,
      var.extra_labels,
    )
    annotations = local.contract_annotations
  }
}

resource "random_password" "s3_access_key" {
  count   = var.backup != "none" && var.create_s3_backup_secret ? 1 : 0
  length  = 20
  special = false
}

resource "random_password" "s3_secret_key" {
  count   = var.backup != "none" && var.create_s3_backup_secret ? 1 : 0
  length  = 40
  special = true
}

resource "kubernetes_secret_v1" "s3_backup" {
  count = var.backup != "none" && var.create_s3_backup_secret ? 1 : 0

  metadata {
    name      = "s3-backup-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels = {
      "aether.shdr.ch/component" = "backup"
    }
  }

  data = {
    AWS_ACCESS_KEY_ID     = random_password.s3_access_key[0].result
    AWS_SECRET_ACCESS_KEY = random_password.s3_secret_key[0].result
    AWS_DEFAULT_REGION    = "us-east-1"
  }

  type = "Opaque"
}
