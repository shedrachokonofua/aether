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

# CONFIDENTIAL + service account + `federated-jwt` authenticator: the
# purpose-built mechanism (KC 26.6, default-on) for authenticating clients
# with Kubernetes SA tokens — NO client secret anywhere on this path. The
# pod presents its projected SA token as a client assertion; Keycloak
# validates it against the cluster JWKS via the IdP below and looks the
# client up by the jwt.credential.* attributes.
resource "keycloak_openid_client" "cloud_audit" {
  realm_id  = keycloak_realm.aether.id
  client_id = "cloud-audit"
  name      = "Cloud Audit (vigil)"
  enabled   = true

  access_type               = "CONFIDENTIAL"
  service_accounts_enabled  = true
  client_authenticator_type = "federated-jwt"

  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  consent_required             = false

  # The lookup pin (DefaultClientAssertionStrategy): assertion sub must equal
  # jwt.credential.sub, and jwt.credential.issuer must name the IdP alias.
  # Any other SA's token fails this lookup — verified live.
  extra_config = {
    "jwt.credential.issuer" = keycloak_oidc_identity_provider.talos_k8s.alias
    "jwt.credential.sub"    = "system:serviceaccount:cloud-audit:vigil"
  }
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

# The cluster-issuer trust, provider type `kubernetes` (purpose-built for SA
# token client assertions). Talos issues SA tokens under
# --service-account-issuer=https://oidc.k8s.home.shdr.ch; the Caddy gateway
# proxies only the two discovery paths to the apiserver VIP, and the
# oidc_discovery_public ClusterRoleBinding permits anonymous reads
# (tofu/home/kubernetes/oidc_discovery.tf) — verified live from the Keycloak VM.
#
# Created during the acceptance investigation and imported into state
# (import block in tofu/main.tf); tofu now owns it.
resource "keycloak_oidc_identity_provider" "talos_k8s" {
  realm       = keycloak_realm.aether.id
  alias       = "talos-k8s-fed"
  provider_id = "kubernetes"
  enabled     = true

  issuer = "https://oidc.k8s.home.shdr.ch"

  # Inert for provider_id=kubernetes (no OIDC login/userinfo flow exists for
  # a k8s issuer; the provider type validates SA tokens against the
  # issuer's discovery document). Required by the provider schema only.
  authorization_url = "https://oidc.k8s.home.shdr.ch"
  token_url         = "https://oidc.k8s.home.shdr.ch"
  user_info_url     = "https://oidc.k8s.home.shdr.ch"
  client_id         = "validation-only"
  client_secret     = "validation-only"
}

# =============================================================================
# Client authentication flow: built-in `clients` flow + federated-jwt
# =============================================================================
# Realms created before client-auth-federated existed never get the
# federated-jwt execution (verified live: absent from `clients` executions,
# and built-in flows reject additions). A replica flow with the execution
# added, bound realm-wide via client_authentication_flow (keycloak.tf).
# Requirements stay ALTERNATIVE for every method — additive only, existing
# client auth (client-secret etc.) is untouched.

resource "keycloak_authentication_flow" "clients_federated" {
  realm_id    = "aether"
  alias       = "clients-federated"
  provider_id = "client-flow"
  description = "Built-in clients flow plus federated-jwt (k8s SA client assertions)"
}

resource "keycloak_authentication_execution" "client_jwt" {
  realm_id          = "aether"
  parent_flow_alias = keycloak_authentication_flow.clients_federated.alias
  authenticator     = "client-jwt"
  requirement       = "ALTERNATIVE"
  priority          = 10
}

resource "keycloak_authentication_execution" "client_secret" {
  realm_id          = "aether"
  parent_flow_alias = keycloak_authentication_flow.clients_federated.alias
  authenticator     = "client-secret"
  requirement       = "ALTERNATIVE"
  priority          = 20
}

resource "keycloak_authentication_execution" "client_secret_jwt" {
  realm_id          = "aether"
  parent_flow_alias = keycloak_authentication_flow.clients_federated.alias
  authenticator     = "client-secret-jwt"
  requirement       = "ALTERNATIVE"
  priority          = 30
}

resource "keycloak_authentication_execution" "client_x509" {
  realm_id          = "aether"
  parent_flow_alias = keycloak_authentication_flow.clients_federated.alias
  authenticator     = "client-x509"
  requirement       = "ALTERNATIVE"
  priority          = 40
}

resource "keycloak_authentication_execution" "federated_jwt" {
  realm_id          = "aether"
  parent_flow_alias = keycloak_authentication_flow.clients_federated.alias
  authenticator     = "federated-jwt"
  requirement       = "ALTERNATIVE"
  priority          = 50
}

# --- Outputs ---------------------------------------------------------------
# The sub the providers must trust (PLAN.md §1: wire as a resource reference,
# single apply). Both KC auth paths mint the cloud-audit client's
# service-account token, so the sub is the service-account user's id — the
# same value either way, exported here.

output "cloud_audit_sub" {
  description = "Keycloak sub of the cloud-audit client's service-account user — the subject AWS/GCP/OCI trust conditions pin"
  value       = keycloak_openid_client.cloud_audit.service_account_user_id
}

output "cloud_audit_idp_alias" {
  description = "Alias of the kubernetes-typed cluster-issuer IdP the vigil SA token authenticates against"
  value       = keycloak_oidc_identity_provider.talos_k8s.alias
}
