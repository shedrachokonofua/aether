# OpenBao Auth & Secrets for Colony
#
# Colony deploys from its own GitLab project (`so/colony`) into the Aether
# host cluster. Its CI jobs authenticate with GitLab OIDC id_tokens and read
# only the `kv/colony/*` runtime secrets needed by the Colony Tofu module.

# =============================================================================
# JWT Auth Backend — trusts GitLab CI OIDC tokens for Colony
# =============================================================================

resource "vault_jwt_auth_backend" "gitlab_colony" {
  path               = "jwt-gitlab-colony"
  type               = "jwt"
  oidc_discovery_url = "https://gitlab.home.shdr.ch"
  default_role       = "colony-ci"

  tune {
    default_lease_ttl = "30m"
    max_lease_ttl     = "1h"
    token_type        = "default-service"
  }
}

resource "vault_jwt_auth_backend_role" "gitlab_colony_ci" {
  backend        = vault_jwt_auth_backend.gitlab_colony.path
  role_name      = "colony-ci"
  role_type      = "jwt"
  token_policies = [vault_policy.colony_ci.name]
  token_ttl      = 900

  user_claim = "user_email"

  bound_claims = {
    project_path = "so/colony"
  }

  bound_audiences = ["https://bao.home.shdr.ch"]
}

# =============================================================================
# Policy: colony-ci — read Colony runtime secrets during Tofu plan/apply
# =============================================================================

resource "vault_policy" "colony_ci" {
  name   = "colony-ci"
  policy = <<-EOT
    # Vault/OpenBao Terraform provider creates limited child tokens per resource.
    path "auth/token/create" {
      capabilities = ["update"]
    }

    # Colony CI reads runtime provider secrets and writes them into Kubernetes
    # secrets through the Colony-owned Tofu module.
    path "kv/data/colony/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/colony/*" {
      capabilities = ["read", "list"]
    }
  EOT
}
