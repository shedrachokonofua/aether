# =============================================================================
# Seven30 Keycloak Realm — isolated tenant for Seven30 studio applications
# =============================================================================
# Seven30 gets its own realm for application OIDC clients (Vaultwarden, etc.).
# Identity is brokered from the aether realm — co-founders click "Login with
# Aether" and authenticate against their existing aether identity. No duplicate
# accounts, no local passwords in the seven30 realm.
#
# Infrastructure auth (kubectl, OpenBao) stays on the aether realm.
# This realm is for application-level SSO only.
#
# Architecture:
#   aether realm (identity source)
#     ← OIDC broker ← seven30 realm (app clients)
#                        ↑ managed by Crossplane (scoped admin)

# =============================================================================
# Realm
# =============================================================================

resource "keycloak_realm" "seven30" {
  realm   = "seven30"
  enabled = true

  display_name = "Seven30"

  login_theme   = "keycloak.v2"
  account_theme = "keycloak.v3"
  admin_theme   = "keycloak.v2"
  email_theme   = "keycloak"

  sso_session_idle_timeout = "2h"
  sso_session_max_lifespan = "12h"
  access_token_lifespan    = "5m"
  refresh_token_max_reuse  = 0

  smtp_server {
    from = "no-reply@seven30.xyz"
    host = local.vm.messaging_stack.ip
    port = local.vm.messaging_stack.ports.smtp
  }

  security_defenses {
    brute_force_detection {
      permanent_lockout                = false
      max_login_failures               = 5
      wait_increment_seconds           = 60
      quick_login_check_milli_seconds  = 1000
      minimum_quick_login_wait_seconds = 60
      max_failure_wait_seconds         = 900
      failure_reset_time_seconds       = 43200
    }
  }
}

# =============================================================================
# Auto-redirect to aether IdP (no local login form)
# =============================================================================
# Configure the built-in browser flow's Identity Provider Redirector to
# default to the aether IdP. Users are sent straight to aether — no
# username/password form, no "Login with Aether" button to click.

data "keycloak_authentication_execution" "seven30_browser_idp_redirector" {
  realm_id          = keycloak_realm.seven30.id
  parent_flow_alias = "browser"
  provider_id       = "identity-provider-redirector"
}

resource "keycloak_authentication_execution_config" "seven30_idp_redirector_config" {
  realm_id     = keycloak_realm.seven30.id
  execution_id = data.keycloak_authentication_execution.seven30_browser_idp_redirector.id
  alias        = "aether-redirect"
  config = {
    defaultProvider = "aether"
  }

  depends_on = [keycloak_oidc_identity_provider.aether]
}

# =============================================================================
# Identity Provider — broker to aether realm
# =============================================================================
# Co-founders authenticate against the aether realm. The seven30 realm trusts
# aether's identity and creates linked local users on first login.

# Client in the aether realm that the seven30 IdP uses to authenticate
resource "keycloak_openid_client" "seven30_broker" {
  realm_id  = keycloak_realm.aether.id
  client_id = "seven30-broker"
  name      = "Seven30 Identity Broker"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false

  valid_redirect_uris = [
    "https://auth.shdr.ch/realms/seven30/broker/aether/endpoint",
  ]

  web_origins = [
    "https://auth.shdr.ch",
  ]
}

resource "keycloak_openid_client_default_scopes" "seven30_broker_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.seven30_broker.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

# Map aether realm roles → "groups" claim in broker tokens
resource "keycloak_openid_user_realm_role_protocol_mapper" "seven30_broker_groups" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.seven30_broker.id
  name      = "groups"

  claim_name          = "groups"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# Identity provider in the seven30 realm pointing to aether
resource "keycloak_oidc_identity_provider" "aether" {
  realm             = keycloak_realm.seven30.id
  alias             = "aether"
  display_name      = "Login with Aether"
  enabled           = true

  authorization_url = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/auth"
  token_url         = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/token"
  user_info_url     = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/userinfo"
  jwks_url          = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/certs"
  issuer            = "https://auth.shdr.ch/realms/aether"
  logout_url        = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/logout"

  client_id     = keycloak_openid_client.seven30_broker.client_id
  client_secret = keycloak_openid_client.seven30_broker.client_secret

  default_scopes = "openid profile email"
  sync_mode      = "FORCE"
  trust_email    = true
  store_token    = false

  validate_signature = true

  extra_config = {
    "clientAuthMethod" = "client_secret_post"
  }
}

# =============================================================================
# Access Control — only aether users with seven30-developer role can broker in
# =============================================================================

resource "keycloak_custom_identity_provider_mapper" "seven30_access_filter" {
  realm                    = keycloak_realm.seven30.id
  name                     = "require-seven30-developer"
  identity_provider_alias  = keycloak_oidc_identity_provider.aether.alias
  identity_provider_mapper = "oidc-advanced-group-idp-mapper"

  extra_config = {
    syncMode = "FORCE"
    claims   = jsonencode([{ key = "groups", value = "seven30-developer" }])
    are      = "PRESENT"
  }
}

# =============================================================================
# Crossplane Service Account — master realm for provider init compatibility
# =============================================================================
# The Terraform Keycloak provider requires master realm auth for its
# initialization (server version check). The service account gets admin
# access via the master realm, scoped to managing seven30 realm resources
# by convention in the Crossplane ProviderConfig.

resource "keycloak_openid_client" "seven30_crossplane" {
  realm_id  = "master"
  client_id = "seven30-crossplane"
  name      = "Seven30 Crossplane Service Account"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
}

resource "keycloak_openid_client_service_account_realm_role" "seven30_crossplane_admin" {
  realm_id                = "master"
  service_account_user_id = keycloak_openid_client.seven30_crossplane.service_account_user_id
  role                    = "admin"
}