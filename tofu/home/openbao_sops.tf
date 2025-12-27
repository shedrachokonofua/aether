# OpenBao Transit secrets engine for SOPS encryption
#
# Transit provides encryption-as-a-service - SOPS sends data to OpenBao,
# OpenBao encrypts/decrypts server-side. The key never leaves OpenBao.
#
# Prerequisites:
#   - OpenBao must be initialized and unsealed
#   - Run: task bao:login
#   - Then: task tofu:apply (picks up cached token automatically)

# Enable Transit secrets engine at /aether
resource "vault_mount" "aether" {
  path        = "aether"
  type        = "transit"
  description = "Transit secrets engine for SOPS encryption"
}

# SOPS encryption key (AES256-GCM96, non-exportable)
resource "vault_transit_secret_backend_key" "sops" {
  backend                = vault_mount.aether.path
  name                   = "sops"
  type                   = "aes256-gcm96"
  exportable             = false
  allow_plaintext_backup = false
}

# Policy for SOPS encrypt/decrypt operations
resource "vault_policy" "sops" {
  name   = "sops"
  policy = <<-EOT
    # SOPS policy - encrypt/decrypt operations

    path "aether/encrypt/sops" {
      capabilities = ["update"]
    }

    path "aether/decrypt/sops" {
      capabilities = ["update"]
    }

    path "aether/keys/sops" {
      capabilities = ["read"]
    }
  EOT
}

output "sops_transit_uri" {
  description = "Transit URI for .sops.yaml (hc_vault_transit_uri)"
  value       = "https://bao.home.shdr.ch/v1/aether/keys/sops"
}

# =============================================================================
# OIDC Auth - Keycloak integration
# =============================================================================

resource "vault_jwt_auth_backend" "keycloak" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = "https://auth.shdr.ch/realms/aether"
  oidc_client_id     = keycloak_openid_client.openbao.client_id
  oidc_client_secret = keycloak_openid_client.openbao.client_secret
  default_role       = "default"

  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "8h"
    token_type        = "default-service"
  }
}

# Default role - all authenticated users get sops policy
resource "vault_jwt_auth_backend_role" "default" {
  backend        = vault_jwt_auth_backend.keycloak.path
  role_name      = "default"
  role_type      = "oidc"
  token_policies = ["default", "sops"]

  user_claim  = "preferred_username"
  oidc_scopes = ["openid", "profile", "email"]
  allowed_redirect_uris = [
    "https://bao.home.shdr.ch/ui/vault/auth/oidc/oidc/callback",
    "https://bao.home.shdr.ch/oidc/callback",
  ]
}

# Admin role - Keycloak "admin" role gets admin + sops policies
resource "vault_jwt_auth_backend_role" "admin" {
  backend        = vault_jwt_auth_backend.keycloak.path
  role_name      = "admin"
  role_type      = "oidc"
  token_policies = ["admin", "sops"]

  user_claim   = "preferred_username"
  bound_claims = { "roles" = "admin" } # Matches keycloak_role.admin
  oidc_scopes  = ["openid", "profile", "email"]
  allowed_redirect_uris = [
    "https://bao.home.shdr.ch/ui/vault/auth/oidc/oidc/callback",
    "https://bao.home.shdr.ch/oidc/callback",
  ]
}

# Admin policy - full access
resource "vault_policy" "admin" {
  name   = "admin"
  policy = <<-EOT
    # Admin policy - full access
    path "*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
  EOT
}

