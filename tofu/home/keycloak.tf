# Keycloak Configuration
# Note: Keycloak LXC is provisioned by Ansible BEFORE tofu apply
# This file only configures Keycloak itself (realm, clients, users)


provider "keycloak" {
  client_id = "admin-cli"
  username  = var.keycloak_admin_username
  password  = var.keycloak_admin_password
  url       = "https://auth.shdr.ch"
}

# =============================================================================
# Master Realm - Admin Users & Service Accounts
# =============================================================================

# Reference the master realm admin role
data "keycloak_role" "master_admin" {
  realm_id = "master"
  name     = "admin"
}

# Personal admin user in master realm (for Keycloak administration)
resource "keycloak_user" "shdrch_master" {
  realm_id       = "master"
  username       = "shdrch"
  enabled        = true
  email          = var.keycloak_shdrch_email
  email_verified = true
  first_name     = "Shedrach"
  last_name      = "Okonofua"

  initial_password {
    value     = var.keycloak_shdrch_initial_password
    temporary = true # Force password change on first login
  }

  lifecycle {
    ignore_changes = [initial_password]
  }
}

# Give shdrch full admin access in master realm
resource "keycloak_user_roles" "shdrch_master_admin" {
  realm_id = "master"
  user_id  = keycloak_user.shdrch_master.id
  role_ids = [data.keycloak_role.master_admin.id]
}

# GitLab CI service account for programmatic realm/client management
resource "keycloak_openid_client" "gitlab_ci" {
  realm_id  = "master"
  client_id = "gitlab-ci"
  name      = "GitLab CI Service Account"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
}

# Give GitLab CI service account admin access (can create realms, manage clients)
resource "keycloak_openid_client_service_account_realm_role" "gitlab_ci_admin" {
  realm_id                = "master"
  service_account_user_id = keycloak_openid_client.gitlab_ci.service_account_user_id
  role                    = "admin"
}

# Aether Realm
resource "keycloak_realm" "aether" {
  realm   = "aether"
  enabled = true

  display_name = "Aether"

  login_theme   = "keycloak.v2"
  account_theme = "keycloak.v3"
  admin_theme   = "keycloak.v2"
  email_theme   = "keycloak"

  # Session settings
  sso_session_idle_timeout = "30m"
  sso_session_max_lifespan = "10h"
  access_token_lifespan    = "5m"
  refresh_token_max_reuse  = 0

  # Security
  password_policy = "length(12) and notUsername"
}

# =============================================================================
# Aether Realm - Roles
# =============================================================================

# Global admin role
resource "keycloak_role" "admin" {
  realm_id    = keycloak_realm.aether.id
  name        = "admin"
  description = "Full administrator access to all services"
}

resource "keycloak_role" "grafana_editor" {
  realm_id    = keycloak_realm.aether.id
  name        = "grafana-editor"
  description = "Grafana Editor"
}

resource "keycloak_role" "grafana_viewer" {
  realm_id    = keycloak_realm.aether.id
  name        = "grafana-viewer"
  description = "Grafana Viewer"
}

resource "keycloak_role" "openwebui_user" {
  realm_id    = keycloak_realm.aether.id
  name        = "openwebui-user"
  description = "Open WebUI User"
}

# =============================================================================
# Aether Realm - Application Users
# =============================================================================

# Personal user in aether realm (for logging into apps like Grafana)
resource "keycloak_user" "shdrch_aether" {
  realm_id       = keycloak_realm.aether.id
  username       = "shdrch"
  enabled        = true
  email          = var.keycloak_shdrch_email
  email_verified = true
  first_name     = "Shedrach"
  last_name      = "Okonofua"

  initial_password {
    value     = var.keycloak_shdrch_initial_password
    temporary = true # Force password change on first login
  }

  lifecycle {
    ignore_changes = [initial_password]
  }
}

resource "keycloak_user_roles" "shdrch_aether_roles" {
  realm_id = keycloak_realm.aether.id
  user_id  = keycloak_user.shdrch_aether.id
  role_ids = [
    keycloak_role.admin.id,
  ]
}

# =============================================================================
# Aether Realm - OIDC Clients
# =============================================================================

# Grafana OIDC Client
resource "keycloak_openid_client" "grafana" {
  realm_id  = keycloak_realm.aether.id
  client_id = "grafana"
  name      = "Grafana"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = true

  root_url  = "https://grafana.home.shdr.ch"
  base_url  = "https://grafana.home.shdr.ch"
  admin_url = "https://grafana.home.shdr.ch"

  valid_redirect_uris = [
    "https://grafana.home.shdr.ch/login/generic_oauth",
  ]

  web_origins = [
    "https://grafana.home.shdr.ch",
  ]
}

# Default scopes for Grafana
resource "keycloak_openid_client_default_scopes" "grafana_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.grafana.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

# Open WebUI OIDC Client
resource "keycloak_openid_client" "openwebui" {
  realm_id  = keycloak_realm.aether.id
  client_id = "openwebui"
  name      = "Open WebUI"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false

  root_url  = "https://openwebui.home.shdr.ch"
  base_url  = "https://openwebui.home.shdr.ch"
  admin_url = "https://openwebui.home.shdr.ch"

  valid_redirect_uris = [
    "https://openwebui.home.shdr.ch/oauth/oidc/callback",
  ]

  web_origins = [
    "https://openwebui.home.shdr.ch",
  ]
}

# Default scopes for Open WebUI
resource "keycloak_openid_client_default_scopes" "openwebui_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.openwebui.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

# Protocol mapper to expose realm roles at top-level "roles" claim for Open WebUI
# Open WebUI's OAUTH_ROLES_CLAIM doesn't support nested paths like realm_access.roles
resource "keycloak_openid_user_realm_role_protocol_mapper" "openwebui_roles" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.openwebui.id
  name      = "realm-roles"

  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# step-ca OIDC Client (for SSH certificates and user X.509 certs)
resource "keycloak_openid_client" "step_ca" {
  realm_id  = keycloak_realm.aether.id
  client_id = "step-ca"
  name      = "step-ca Certificate Authority"
  enabled   = true

  # Public client - step-ca validates tokens via JWKS, doesn't need secret
  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = true

  # Device authorization for headless SSH login (step ssh login)
  oauth2_device_authorization_grant_enabled = true

  valid_redirect_uris = [
    "http://127.0.0.1:10000/*", # Local callback for step CLI
  ]
}

# Default scopes for step-ca
resource "keycloak_openid_client_default_scopes" "step_ca_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.step_ca.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

# Protocol mapper to expose realm roles at top-level "roles" claim for step-ca
# step-ca SSH templates can then access .Token.roles directly
resource "keycloak_openid_user_realm_role_protocol_mapper" "step_ca_roles" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.step_ca.id
  name      = "realm-roles"

  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# GitLab OIDC Client (for user SSO login - separate from gitlab_ci service account)
resource "keycloak_openid_client" "gitlab" {
  realm_id  = keycloak_realm.aether.id
  client_id = "gitlab"
  name      = "GitLab"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false

  root_url  = "https://gitlab.home.shdr.ch"
  base_url  = "https://gitlab.home.shdr.ch"
  admin_url = "https://gitlab.home.shdr.ch"

  valid_redirect_uris = [
    "https://gitlab.home.shdr.ch/users/auth/openid_connect/callback",
  ]

  web_origins = [
    "https://gitlab.home.shdr.ch",
  ]
}

# Default scopes for GitLab
resource "keycloak_openid_client_default_scopes" "gitlab_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.gitlab.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

# Protocol mapper to expose realm roles as "groups" claim for GitLab
# GitLab's admin_groups expects roles in a "groups" array
resource "keycloak_openid_user_realm_role_protocol_mapper" "gitlab_groups" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.gitlab.id
  name      = "groups"

  claim_name          = "groups"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

