# =============================================================================
# Pharos OIDC Client (aether realm)
# =============================================================================
# Confidential authorization-code client for the Pharos web app
# (tofu/home/kubernetes/pharos.tf). The app does its own server-side OIDC login
# (/auth/login -> /auth/callback), checks `preferred_username` against its
# PHAROS_ALLOWED_USERS allowlist (`shdrch`) and keeps only a signed session
# cookie; no OAuth tokens reach the browser. The client secret flows to the
# kubernetes module as pharos_oauth_client_secret (talos_cluster.tf) and into
# the pharos-env Secret.

resource "keycloak_openid_client" "pharos" {
  realm_id  = keycloak_realm.aether.id
  client_id = "pharos"
  name      = "Pharos"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false

  root_url  = "https://pharos.home.shdr.ch"
  base_url  = "https://pharos.home.shdr.ch"
  admin_url = "https://pharos.home.shdr.ch"

  valid_redirect_uris = [
    "https://pharos.home.shdr.ch/auth/callback",
  ]

  valid_post_logout_redirect_uris = [
    "https://pharos.home.shdr.ch/",
  ]

  web_origins = [
    "https://pharos.home.shdr.ch",
  ]
}

resource "keycloak_openid_client_default_scopes" "pharos_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.pharos.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}
