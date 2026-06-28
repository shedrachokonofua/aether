# =============================================================================
# OpenBao Auth & Secrets for Osemu-Ehis Farms
# =============================================================================

# 1. Dedicated Transit Engine for Farms SOPS encryption
resource "vault_mount" "farms_transit" {
  path        = "osemu-ehis-farms"
  type        = "transit"
  description = "Transit secrets engine for Osemu-Ehis Farms SOPS encryption"
}

# 2. SOPS encryption key
resource "vault_transit_secret_backend_key" "farms_sops" {
  backend = vault_mount.farms_transit.path
  name    = "sops"
  type    = "aes256-gcm96"
}

# 3. Dedicated Policy for Farms CI
resource "vault_policy" "farms_ci" {
  name   = "osemu-ehis-farms-ci"
  policy = <<-EOT
    # Allow creating limited child tokens (required by Terraform/OpenTofu provider)
    path "auth/token/create" {
      capabilities = ["update"]
    }

    # SOPS encryption/decryption operations for Farms
    path "osemu-ehis-farms/encrypt/sops" {
      capabilities = ["update"]
    }
    path "osemu-ehis-farms/decrypt/sops" {
      capabilities = ["update"]
    }
    path "osemu-ehis-farms/keys/sops" {
      capabilities = ["read"]
    }
  EOT
}

# 4. GitLab CI OIDC Role for Farms
resource "vault_jwt_auth_backend_role" "gitlab_farms_ci" {
  backend        = vault_jwt_auth_backend.gitlab.path
  role_name      = "farms-ci"
  role_type      = "jwt"
  token_policies = [vault_policy.farms_ci.name]
  token_ttl      = 900 # 15 minutes

  user_claim = "user_email"

  # Authorize only the osemu-ehis-farms GitLab projects
  bound_claims_type = "glob"
  bound_claims = {
    "project_path" = "so/osemu-ehis-farms/*"
  }

  bound_audiences = ["https://bao.home.shdr.ch"]
}
