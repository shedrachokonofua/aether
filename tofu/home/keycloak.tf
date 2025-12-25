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
# GitLab CI Identity Provider (for token exchange)
# =============================================================================

resource "keycloak_oidc_identity_provider" "gitlab_ci" {
  realm        = keycloak_realm.aether.id
  alias        = "gitlab-ci"
  display_name = "GitLab CI"
  enabled      = true

  issuer            = "https://gitlab.home.shdr.ch"
  authorization_url = "https://gitlab.home.shdr.ch/oauth/authorize"
  token_url         = "https://gitlab.home.shdr.ch/oauth/token"
  jwks_url          = "https://gitlab.home.shdr.ch/oauth/discovery/keys"

  client_id     = "https://gitlab.home.shdr.ch"
  client_secret = "unused"

  trust_email        = false
  link_only          = false
  store_token        = false
  validate_signature = true

  disable_user_info        = true
  hide_on_login_page       = true
  disable_type_claim_check = true
}

resource "keycloak_custom_identity_provider_mapper" "gitlab_ci_username" {
  realm                    = keycloak_realm.aether.id
  name                     = "project-branch-username"
  identity_provider_alias  = keycloak_oidc_identity_provider.gitlab_ci.alias
  identity_provider_mapper = "oidc-username-idp-mapper"

  extra_config = {
    "syncMode" = "INHERIT"
    "template" = "gitlab_ci/$${CLAIM.project_path}/$${CLAIM.ref}"
  }
}

resource "keycloak_custom_identity_provider_mapper" "gitlab_ci_deploy_role" {
  realm                    = keycloak_realm.aether.id
  name                     = "ci-deploy-role"
  identity_provider_alias  = keycloak_oidc_identity_provider.gitlab_ci.alias
  identity_provider_mapper = "oidc-hardcoded-role-idp-mapper"

  extra_config = {
    "syncMode" = "INHERIT"
    "role"     = "ci-deploy"
  }
}

resource "keycloak_role" "ci_deploy" {
  realm_id    = keycloak_realm.aether.id
  name        = "ci-deploy"
  description = "Role for CI/CD deployments"
}

# =============================================================================
# CI Deploy Client (for token exchange flow)
# =============================================================================

resource "keycloak_openid_client" "ci_deploy" {
  realm_id  = keycloak_realm.aether.id
  client_id = "ci-deploy"
  name      = "CI Deploy Token Exchange"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false
}

resource "keycloak_openid_client_default_scopes" "ci_deploy_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.ci_deploy.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "ci_deploy_roles" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.ci_deploy.id
  name      = "realm-roles"

  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

resource "keycloak_openid_audience_protocol_mapper" "ci_deploy_audience" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.ci_deploy.id
  name      = "ci-deploy-audience"

  included_client_audience = keycloak_openid_client.ci_deploy.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

resource "keycloak_openid_user_property_protocol_mapper" "ci_deploy_subject" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.ci_deploy.id
  name      = "subject"

  user_property       = "username"
  claim_name          = "sub"
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

resource "keycloak_identity_provider_token_exchange_scope_permission" "gitlab_ci_token_exchange" {
  realm_id       = keycloak_realm.aether.id
  provider_alias = keycloak_oidc_identity_provider.gitlab_ci.alias
  policy_type    = "client"
  clients        = [keycloak_openid_client.ci_deploy.id]
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

