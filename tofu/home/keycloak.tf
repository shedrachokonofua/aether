provider "keycloak" {
  client_id = "admin-cli"
  username  = var.keycloak_admin_username
  password  = var.keycloak_admin_password
  url       = "https://auth.shdr.ch"
}

# =============================================================================
# Master Realm - Admin Users & Service Accounts
# =============================================================================

data "keycloak_role" "master_admin" {
  realm_id = "master"
  name     = "admin"
}

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
    temporary = true
  }

  lifecycle {
    ignore_changes = [initial_password]
  }
}

resource "keycloak_user_roles" "shdrch_master_admin" {
  realm_id = "master"
  user_id  = keycloak_user.shdrch_master.id
  role_ids = [data.keycloak_role.master_admin.id]
}

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

resource "keycloak_openid_client_service_account_realm_role" "gitlab_ci_admin" {
  realm_id                = "master"
  service_account_user_id = keycloak_openid_client.gitlab_ci.service_account_user_id
  role                    = "admin"
}

resource "keycloak_realm" "aether" {
  realm   = "aether"
  enabled = true

  display_name = "Aether"

  login_theme   = "keycloak.v2"
  account_theme = "keycloak.v3"
  admin_theme   = "keycloak.v2"
  email_theme   = "keycloak"

  sso_session_idle_timeout = "30m"
  sso_session_max_lifespan = "10h"
  access_token_lifespan    = "5m"
  refresh_token_max_reuse  = 0
  password_policy          = "length(12) and notUsername"

  smtp_server {
    from = "no-reply@shdr.ch"
    host = local.vm.messaging_stack.ip
    port = local.vm.messaging_stack.ports.smtp
  }
}

# =============================================================================
# Aether Realm - Roles
# =============================================================================

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
    temporary = true
  }

  lifecycle {
    ignore_changes = [initial_password]
  }
}

resource "keycloak_user_roles" "shdrch_aether_roles" {
  realm_id = keycloak_realm.aether.id
  user_id  = keycloak_user.shdrch_aether.id
  role_ids = [
    keycloak_role.admin.id
  ]
}

# =============================================================================
# Aether Realm - OIDC Clients
# =============================================================================

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

resource "keycloak_openid_client_default_scopes" "grafana_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.grafana.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

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
    "https://ai.shdr.ch/oauth/oidc/callback",
  ]

  web_origins = [
    "https://openwebui.home.shdr.ch",
    "https://ai.shdr.ch",
  ]
}

resource "keycloak_openid_client_default_scopes" "openwebui_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.openwebui.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

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

resource "keycloak_openid_client" "step_ca" {
  realm_id  = keycloak_realm.aether.id
  client_id = "step-ca"
  name      = "step-ca Certificate Authority"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = true

  oauth2_device_authorization_grant_enabled = true

  valid_redirect_uris = [
    "http://127.0.0.1:10000/*",
  ]
}

resource "keycloak_openid_client_default_scopes" "step_ca_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.step_ca.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

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

resource "keycloak_openid_client_default_scopes" "gitlab_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.gitlab.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

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

# =============================================================================
# Jellyfin OIDC Client (jellyfin-plugin-sso)
# =============================================================================

resource "keycloak_role" "jellyfin_user" {
  realm_id    = keycloak_realm.aether.id
  name        = "jellyfin-user"
  description = "Jellyfin User - allowed to access Jellyfin"
}

resource "keycloak_openid_client" "jellyfin" {
  realm_id  = keycloak_realm.aether.id
  client_id = "jellyfin"
  name      = "Jellyfin"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false

  root_url  = "https://jellyfin.home.shdr.ch"
  base_url  = "https://jellyfin.home.shdr.ch"
  admin_url = "https://jellyfin.home.shdr.ch"

  valid_redirect_uris = [
    "https://jellyfin.home.shdr.ch/sso/OID/redirect/aether",
    "https://tv.shdr.ch/sso/OID/redirect/aether",
  ]

  web_origins = [
    "https://jellyfin.home.shdr.ch",
    "https://tv.shdr.ch",
  ]
}

resource "keycloak_openid_client_default_scopes" "jellyfin_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.jellyfin.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "jellyfin_roles" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.jellyfin.id
  name      = "realm-roles"

  claim_name          = "realm_access.roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# =============================================================================
# OpenBao OIDC Client
# =============================================================================

resource "keycloak_openid_client" "openbao" {
  realm_id  = keycloak_realm.aether.id
  client_id = "openbao"
  name      = "OpenBao"
  enabled   = true

  access_type                               = "CONFIDENTIAL"
  standard_flow_enabled                     = true
  implicit_flow_enabled                     = false
  direct_access_grants_enabled              = true
  oauth2_device_authorization_grant_enabled = true

  root_url  = "https://bao.home.shdr.ch"
  base_url  = "https://bao.home.shdr.ch"
  admin_url = "https://bao.home.shdr.ch"

  valid_redirect_uris = [
    "https://bao.home.shdr.ch/ui/vault/auth/oidc/oidc/callback",
    "https://bao.home.shdr.ch/oidc/callback",
  ]

  web_origins = [
    "https://bao.home.shdr.ch",
  ]
}

resource "keycloak_openid_client_default_scopes" "openbao_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.openbao.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "openbao_roles" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.openbao.id
  name      = "realm-roles"

  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

resource "keycloak_openid_audience_protocol_mapper" "openbao_audience" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.openbao.id
  name      = "openbao-audience"

  included_client_audience = keycloak_openid_client.openbao.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

