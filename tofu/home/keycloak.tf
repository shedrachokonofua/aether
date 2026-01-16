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

  # Prompt to configure MFA on next login
  required_actions = ["CONFIGURE_TOTP"]

  initial_password {
    value     = var.keycloak_shdrch_initial_password
    temporary = true
  }

  lifecycle {
    ignore_changes = [initial_password, required_actions]
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

  sso_session_idle_timeout = "2h"
  sso_session_max_lifespan = "12h"
  access_token_lifespan    = "5m"
  refresh_token_max_reuse  = 0
  password_policy          = "length(12) and notUsername"

  smtp_server {
    from = "no-reply@shdr.ch"
    host = local.vm.messaging_stack.ip
    port = local.vm.messaging_stack.ports.smtp
  }

  # Brute force detection
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
# Aether Realm - MFA Configuration
# =============================================================================

# Enable MFA options (available to all, required for admins)
resource "keycloak_required_action" "configure_otp" {
  realm_id       = keycloak_realm.aether.id
  alias          = "CONFIGURE_TOTP"
  enabled        = true
  default_action = false
}

resource "keycloak_required_action" "webauthn_register" {
  realm_id       = keycloak_realm.aether.id
  alias          = "webauthn-register"
  enabled        = true
  default_action = false
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

  # Prompt to configure MFA on next login
  required_actions = ["webauthn-register", "CONFIGURE_TOTP"]

  initial_password {
    value     = var.keycloak_shdrch_initial_password
    temporary = true
  }

  lifecycle {
    ignore_changes = [initial_password, required_actions]
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

# =============================================================================
# Ceph RGW OIDC Client (STS)
# =============================================================================
# Public client for device authorization + STS AssumeRoleWithWebIdentity

resource "keycloak_openid_client" "ceph_rgw" {
  realm_id  = keycloak_realm.aether.id
  client_id = "ceph-rgw"
  name      = "Ceph RGW"
  enabled   = true

  # PUBLIC client - device auth doesn't support client secrets
  access_type                  = "PUBLIC"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  consent_required             = false

  oauth2_device_authorization_grant_enabled = true
}

resource "keycloak_openid_client_default_scopes" "ceph_rgw_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.ceph_rgw.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "ceph_rgw_roles" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.ceph_rgw.id
  name      = "realm-roles"

  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

resource "keycloak_openid_audience_protocol_mapper" "ceph_rgw_audience" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.ceph_rgw.id
  name      = "ceph-rgw-audience"

  included_client_audience = keycloak_openid_client.ceph_rgw.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

# =============================================================================
# Toolbox Client - Unified Developer Login
# =============================================================================
# Public client for device authorization grant (CLI login without browser redirect).
# Used by `task login` to authenticate developers and exchange tokens for:
#   - AWS (via STS AssumeRoleWithWebIdentity)
#   - OpenBao (via JWT auth backend)
#   - step-ca SSH certs (optional, via OIDC provisioner)

resource "keycloak_openid_client" "toolbox" {
  realm_id  = keycloak_realm.aether.id
  client_id = "toolbox"
  name      = "Aether Toolbox"
  enabled   = true

  # PUBLIC client - device auth doesn't support client secrets
  access_type                  = "PUBLIC"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  consent_required             = false # Skip grant screen for trusted client

  # Device authorization grant - the key feature for CLI auth
  oauth2_device_authorization_grant_enabled = true
}

# Note: Role check happens at downstream systems (OpenBao JWT auth, AWS could use sub claim)
# Keycloak client authorization requires CONFIDENTIAL client which breaks device auth flow

resource "keycloak_openid_client_default_scopes" "toolbox_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.toolbox.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

# Add realm roles to tokens (for AWS role mapping)
resource "keycloak_openid_user_realm_role_protocol_mapper" "toolbox_roles" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.toolbox.id
  name      = "realm-roles"

  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# Add audience claim for OpenBao JWT auth
resource "keycloak_openid_audience_protocol_mapper" "toolbox_openbao_audience" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.toolbox.id
  name      = "openbao-audience"

  included_client_audience = keycloak_openid_client.openbao.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

# Add audience claim for AWS (client ID in STS call)
resource "keycloak_openid_audience_protocol_mapper" "toolbox_audience" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.toolbox.id
  name      = "toolbox-audience"

  included_client_audience = keycloak_openid_client.toolbox.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

# =============================================================================
# Fleet SAML Client (osquery management)
# =============================================================================
# Fleet uses SAML (not OIDC) for SSO authentication.
# Used for: Admin access to Fleet osquery management UI

resource "keycloak_saml_client" "fleet" {
  realm_id  = keycloak_realm.aether.id
  client_id = "fleet"
  name      = "Fleet"
  enabled   = true

  sign_documents          = true
  sign_assertions         = true
  include_authn_statement = true

  signature_algorithm    = "RSA_SHA256"
  signature_key_name     = "KEY_ID"
  canonicalization_method = "EXCLUSIVE"

  name_id_format = "email"

  root_url            = "https://fleet.home.shdr.ch"
  base_url            = "https://fleet.home.shdr.ch"
  master_saml_processing_url = "https://fleet.home.shdr.ch/api/v1/fleet/sso"

  valid_redirect_uris = [
    "https://fleet.home.shdr.ch/api/v1/fleet/sso/callback",
  ]

  idp_initiated_sso_url_name = "fleet"
}

# =============================================================================
# Kubernetes OIDC Client
# =============================================================================
# Public client for kubectl authentication via kubelogin/oidc-login plugin.
# Supports device authorization grant for CLI login without browser redirect.
# Used for: kubectl access to Talos Kubernetes cluster

resource "keycloak_openid_client" "kubernetes" {
  realm_id  = keycloak_realm.aether.id
  client_id = "kubernetes"
  name      = "Kubernetes"
  enabled   = true

  # PUBLIC client - kubelogin doesn't require client secret
  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false

  # Device authorization grant for CLI auth (kubelogin)
  oauth2_device_authorization_grant_enabled = true

  # kubelogin callback URLs + Headlamp
  valid_redirect_uris = [
    "http://localhost:8000/*",
    "http://localhost:18000/*",
    "http://127.0.0.1:8000/*",
    "http://127.0.0.1:18000/*",
    "https://headlamp.apps.home.shdr.ch/oidc-callback",
  ]

  web_origins = [
    "https://headlamp.apps.home.shdr.ch",
  ]
}

resource "keycloak_openid_client_default_scopes" "kubernetes_default_scopes" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.kubernetes.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}

# Add groups claim for Kubernetes RBAC
resource "keycloak_openid_user_realm_role_protocol_mapper" "kubernetes_groups" {
  realm_id  = keycloak_realm.aether.id
  client_id = keycloak_openid_client.kubernetes.id
  name      = "groups"

  claim_name          = "groups"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}


