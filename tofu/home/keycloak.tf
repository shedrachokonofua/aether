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

# Grafana roles (mapped via role_attribute_path in Grafana config)
resource "keycloak_role" "grafana_admin" {
  realm_id    = keycloak_realm.aether.id
  name        = "grafana-admin"
  description = "Grafana Administrator"
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

# Give shdrch admin role for Grafana
resource "keycloak_user_roles" "shdrch_aether_roles" {
  realm_id = keycloak_realm.aether.id
  user_id  = keycloak_user.shdrch_aether.id
  role_ids = [keycloak_role.grafana_admin.id]
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
    "openid",
    "roles",
  ]
}

