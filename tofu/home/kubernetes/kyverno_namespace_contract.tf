# =============================================================================
# Kyverno namespace contract policies
# =============================================================================
# Audit-only during namespace adoption. The namespace module is the writer for the
# aether.shdr.ch/* labels; this policy exposes any out-of-band namespace without
# blocking sibling repos or controllers during the migration window.

resource "kubectl_manifest" "kyverno_namespace_contract_labels" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1alpha1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "namespace-contract-labels"
      annotations = {
        "policies.kyverno.io/title"       = "Namespace Contract Labels"
        "policies.kyverno.io/category"    = "Namespace Governance"
        "policies.kyverno.io/subject"     = "Namespace"
        "policies.kyverno.io/description" = "Audit namespaces that do not declare the required aether.shdr.ch/tier, owner, backup, and exposure contract labels."
      }
    }
    spec = {
      failurePolicy     = "Ignore"
      validationActions = ["Audit"]
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["namespaces"]
          scope       = "Cluster"
        }]
      }
      validations = [{
        expression = "has(object.metadata.labels) && ['aether.shdr.ch/tier', 'aether.shdr.ch/owner', 'aether.shdr.ch/backup', 'aether.shdr.ch/exposure'].all(key, key in object.metadata.labels && object.metadata.labels[key] != '')"
        message    = "Namespaces must carry aether.shdr.ch/tier, owner, backup, and exposure labels."
        reason     = "Invalid"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_namespace_contract_stamper" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1alpha1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "namespace-contract-stamper"
      annotations = {
        "policies.kyverno.io/title"       = "Namespace Contract Stamper"
        "policies.kyverno.io/category"    = "Namespace Governance"
        "policies.kyverno.io/subject"     = "Namespace"
        "policies.kyverno.io/description" = "Fail-open quarantine stamper for namespaces that arrive without the aether.shdr.ch contract labels or derived default labels."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["namespaces"]
          scope       = "Cluster"
        }]
      }
      matchConditions = [{
        name       = "missing-contract-or-default-label"
        expression = "!has(object.metadata.labels) || [\"aether.shdr.ch/tier\", \"aether.shdr.ch/owner\", \"aether.shdr.ch/backup\", \"aether.shdr.ch/exposure\", \"pod-security.kubernetes.io/enforce\", \"pod-security.kubernetes.io/audit\", \"pod-security.kubernetes.io/warn\", \"goldilocks.fairwinds.com/enabled\", \"istio.io/dataplane-mode\", \"aether.shdr.ch/gateway-access\", \"aether.shdr.ch/registry-access\"].exists(key, !(key in object.metadata.labels) || object.metadata.labels[key] == \"\")"
      }]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            (!has(object.metadata.labels) ? [
              JSONPatch{op: "add", path: "/metadata/labels", value: {}}
            ] : []) +
            (!has(object.metadata.labels) || !("aether.shdr.ch/tier" in object.metadata.labels) || object.metadata.labels["aether.shdr.ch/tier"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("aether.shdr.ch/tier"), value: "unclassified"}
            ] : []) +
            (!has(object.metadata.labels) || !("aether.shdr.ch/owner" in object.metadata.labels) || object.metadata.labels["aether.shdr.ch/owner"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("aether.shdr.ch/owner"), value: "unknown"}
            ] : []) +
            (!has(object.metadata.labels) || !("aether.shdr.ch/backup" in object.metadata.labels) || object.metadata.labels["aether.shdr.ch/backup"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("aether.shdr.ch/backup"), value: "none"}
            ] : []) +
            (!has(object.metadata.labels) || !("aether.shdr.ch/exposure" in object.metadata.labels) || object.metadata.labels["aether.shdr.ch/exposure"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("aether.shdr.ch/exposure"), value: "none"}
            ] : []) +
            (!has(object.metadata.labels) || !("pod-security.kubernetes.io/enforce" in object.metadata.labels) || object.metadata.labels["pod-security.kubernetes.io/enforce"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("pod-security.kubernetes.io/enforce"), value: "baseline"}
            ] : []) +
            (!has(object.metadata.labels) || !("pod-security.kubernetes.io/audit" in object.metadata.labels) || object.metadata.labels["pod-security.kubernetes.io/audit"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("pod-security.kubernetes.io/audit"), value: "restricted"}
            ] : []) +
            (!has(object.metadata.labels) || !("pod-security.kubernetes.io/warn" in object.metadata.labels) || object.metadata.labels["pod-security.kubernetes.io/warn"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("pod-security.kubernetes.io/warn"), value: "restricted"}
            ] : []) +
            (!has(object.metadata.labels) || !("goldilocks.fairwinds.com/enabled" in object.metadata.labels) || object.metadata.labels["goldilocks.fairwinds.com/enabled"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("goldilocks.fairwinds.com/enabled"), value: "false"}
            ] : []) +
            (!has(object.metadata.labels) || !("istio.io/dataplane-mode" in object.metadata.labels) || object.metadata.labels["istio.io/dataplane-mode"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("istio.io/dataplane-mode"), value: "none"}
            ] : []) +
            (!has(object.metadata.labels) || !("aether.shdr.ch/gateway-access" in object.metadata.labels) || object.metadata.labels["aether.shdr.ch/gateway-access"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("aether.shdr.ch/gateway-access"), value: "none"}
            ] : []) +
            (!has(object.metadata.labels) || !("aether.shdr.ch/registry-access" in object.metadata.labels) || object.metadata.labels["aether.shdr.ch/registry-access"] == "" ? [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("aether.shdr.ch/registry-access"), value: "none"}
            ] : [])
          EOT
        }
      }]
    }
  })
}


resource "kubectl_manifest" "kyverno_namespace_unclassified_report" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1alpha1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "namespace-contract-unclassified"
      annotations = {
        "policies.kyverno.io/title"       = "Unclassified Namespace Contract"
        "policies.kyverno.io/category"    = "Namespace Governance"
        "policies.kyverno.io/subject"     = "Namespace"
        "policies.kyverno.io/description" = "Audit namespaces quarantined by the namespace-contract-stamper with tier=unclassified."
      }
    }
    spec = {
      failurePolicy     = "Ignore"
      validationActions = ["Audit"]
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = true
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["namespaces"]
          scope       = "Cluster"
        }]
      }
      validations = [{
        expression = "!has(object.metadata.labels) || !(\"aether.shdr.ch/tier\" in object.metadata.labels) || object.metadata.labels[\"aether.shdr.ch/tier\"] != \"unclassified\""
        message    = "Namespace is quarantined with aether.shdr.ch/tier=unclassified; add it to local.namespace_contract_specs."
        reason     = "Invalid"
      }]
    }
  })
}
