# =============================================================================
# cloud-audit namespace — vigil (cloud control-plane audit forwarder)
# =============================================================================
# Namespace contract entry lives in namespace_contracts.tf ("cloud-audit").
# This file holds the workload's own resources as they land:
#   - the vigil ServiceAccount (the identity root of the keyless auth chain;
#     its projected token authenticates to Keycloak via federated-jwt and to
#     OpenBao via the JWT role in openbao_cloud_audit.tf)
#
# P2 adds: digest-pinned vigil serve Deployment, cursor PVC, Cilium toFQDNs
# CNP, and the Kyverno ValidatingPolicy (vigil repo PLAN.md §6).

resource "kubernetes_service_account_v1" "vigil" {
  metadata {
    name      = "vigil"
    namespace = module.namespace["cloud-audit"].name
  }

  # No image pull secrets, no token auto-mount annotation: the pod mounts a
  # serviceAccountToken projected volume explicitly (custom audiences), and
  # the Kyverno policy forbids any other credential material.
}
