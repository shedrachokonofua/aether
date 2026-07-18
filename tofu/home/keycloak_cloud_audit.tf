# =============================================================================
# cloud-audit — vigil's keyless identity (PLAN.md §1)
# =============================================================================
# The vigil pod's projected Kubernetes ServiceAccount token is exchanged at
# Keycloak for an aether-realm token carrying aud=cloud-audit. The identity
# root is the k8s SA that the cloud-audit namespace's Kyverno policy already
# pins; nothing static exists on this path.
#
# Chain: pod SA JWT (issuer https://oidc.k8s.home.shdr.ch, audience
# keycloak:cloud-audit, sub system:serviceaccount:cloud-audit:vigil)
#   -> IdP `talos-aether-k8s` (validates signature + issuer against the
#      cluster JWKS; anonymous JWKS via oidc_discovery_public)
#   -> RFC 8693 exchange by the PUBLIC client `cloud-audit` (scope permission
#      below) -> realm token, aud=cloud-audit via the audience mapper
#   -> AWS/GCP/OCI read-only trusts requiring aud=cloud-audit and the
#      exported sub.
#
# Verified 2026-07-17 (PLAN.md P0): Keycloak 26.6.4 has token-exchange:v1 +
# kubernetes-service-accounts:v1 built in; the cluster issuer serves
# discovery+JWKS to the Keycloak VM. The sub on this path is only knowable
# after the first live exchange (first-broker-login creates the mapped user);
# see outputs and PLAN.md's fallback note.

# PUBLIC client: the pod presents only its SA token — no client secret on the
# primary path. (seven30_cli precedent: public client + exchange scope
# permission.)
resource "keycloak_openid_client" "cloud_audit" {
  realm_id  = keycloak_realm.aether.id
  client_id = "cloud-audit"
  name      = "Cloud Audit (vigil)"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  consent_required             = false

  # Fallback path (PLAN.md §1): if external-subject exchange proves unusable,
  # flip to CONFIDENTIAL + service_accounts_enabled and deliver the secret via
  # ESO/Bao. Record which shipped in PLAN.md.
}

# Tokens minted for this client carry aud=cloud-audit — these can never
# satisfy the aud=toolbox conditions on the human/toolbox trusts, and vice
# versa (dedicated-audience isolation).
resource "keycloak_openid_audience_protocol_mapper" "cloud_audit_audience" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.cloud_audit.id
  name      = "cloud-audit-audience"

  included_client_audience = keycloak_openid_client.cloud_audit.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

# The cluster-issuer trust. Talos issues SA tokens under
# --service-account-issuer=https://oidc.k8s.home.shdr.ch; the Caddy gateway
# proxies only the two discovery paths to the apiserver VIP, and the
# oidc_discovery_public ClusterRoleBinding permits anonymous reads
# (tofu/home/kubernetes/oidc_discovery.tf). No browser/login URLs exist for
# this issuer — the IdP is validation-only.
resource "keycloak_oidc_identity_provider" "talos_aether_k8s" {
  realm        = keycloak_realm.aether.id
  alias        = "talos-aether-k8s"
  display_name = "Talos aether-k8s service accounts"
  enabled      = true

  issuer   = "https://oidc.k8s.home.shdr.ch"
  jwks_url = "https://oidc.k8s.home.shdr.ch/openid/v1/jwks"

  # k8s serves no OIDC login endpoints; the provider schema wants these set.
  authorization_url = "https://oidc.k8s.home.shdr.ch"
  token_url         = "https://oidc.k8s.home.shdr.ch"
  user_info_url     = "https://oidc.k8s.home.shdr.ch"

  validate_signature = true
  sync_mode          = "FORCE"
  store_token        = false

  # Required by the provider schema but inert here: the k8s issuer has no
  # token endpoint for Keycloak to call (the IdP validates external tokens
  # against the JWKS; no browser or client-credential flow ever runs).
  client_id     = "validation-only"
  client_secret = "validation-only"

  extra_config = {
    # Accept external tokens (the k8s SA JWT) for exchange. LIVE-ITERATE: if
    # KC 26.6 V1 rejects the exchange, the knobs to revisit are here, the
    # projected-token audience (keycloak:cloud-audit), and the
    # kubernetes-service-accounts client-auth alternative (PLAN.md §1).
    "supportsExternalExchange" = "true"
  }
}

# Only the cloud-audit client may exchange against this IdP.
resource "keycloak_identity_provider_token_exchange_scope_permission" "cloud_audit" {
  realm_id       = keycloak_realm.aether.id
  provider_alias = keycloak_oidc_identity_provider.talos_aether_k8s.alias

  policy_type = "client"
  clients     = [keycloak_openid_client.cloud_audit.id]
}

# --- Outputs ---------------------------------------------------------------
# The sub the providers must trust (PLAN.md §1: wire as a resource reference,
# single apply). On the primary path the sub is the KC-internal id of the
# IdP-brokered user, created at the first live exchange — tofu cannot know it
# ahead of time, so the provider legs pin it via a variable fed from the
# acceptance run (documented in PLAN.md P0). The fallback path's sub is
# deterministic and exported here.

output "cloud_audit_fallback_sub" {
  description = "sub if the client-credentials fallback ships (service-account user of the cloud-audit client); primary path pins the brokered-user sub discovered at acceptance"
  value       = keycloak_openid_client.cloud_audit.service_account_user_id
}

output "cloud_audit_idp_alias" {
  description = "Alias of the cluster-issuer IdP the vigil SA token is exchanged against"
  value       = keycloak_oidc_identity_provider.talos_aether_k8s.alias
}
