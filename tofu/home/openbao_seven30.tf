# OpenBao Auth & Secrets for Seven30
#
# Three auth paths into OpenBao for Seven30:
#   1. JWT (vcluster SA tokens) — ESO pods pull secrets
#   2. JWT (GitLab CI OIDC)     — CI decrypts SOPS + writes secrets
#   3. OIDC/JWT (Keycloak)      — Co-founders manage secrets via CLI/UI
#
# Secrets pipeline:
#   SOPS (seven30/infra) → GitLab CI → OpenBao KV → ESO → K8s Secrets
#
# Prerequisites:
#   - vcluster must be running with OIDC discovery exposed
#   - oidc-discovery-public ClusterRoleBinding in vcluster (bootstrap manifest)
#   - GitLab OIDC discovery at https://gitlab.home.shdr.ch

# =============================================================================
# JWT Auth Backend — trusts vcluster service account tokens
# =============================================================================

resource "vault_jwt_auth_backend" "seven30" {
  path               = "jwt-seven30"
  type               = "jwt"
  jwks_url           = "https://k8s.seven30.xyz/openid/v1/jwks"
  default_role       = "external-secrets"

  # No bound_issuer set — vcluster SA issuer varies; signature-only validation

  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "4h"
    token_type        = "default-service"
  }
}

# =============================================================================
# Role: external-secrets — for ESO pods to pull secrets
# =============================================================================

resource "vault_jwt_auth_backend_role" "seven30_external_secrets" {
  backend   = vault_jwt_auth_backend.seven30.path
  role_name = "external-secrets"
  role_type = "jwt"

  token_policies = [vault_policy.seven30_secrets.name]
  token_ttl      = 3600  # 1 hour

  user_claim = "sub"

  # Bind to the ESO service account in the vcluster
  bound_claims = {
    "sub" = "system:serviceaccount:default:external-secrets"
  }

  # Accept tokens intended for OpenBao
  bound_audiences = ["https://bao.home.shdr.ch"]
}

# =============================================================================
# Policy: seven30-secrets — read-only access to kv/data/seven30/*
# =============================================================================

resource "vault_policy" "seven30_secrets" {
  name   = "seven30-secrets"
  policy = <<-EOT
    # Read Seven30 secrets
    path "kv/data/seven30/*" {
      capabilities = ["read"]
    }

    # List secret keys (for ESO discovery)
    path "kv/metadata/seven30/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

# =============================================================================
# Policy: seven30-developer — read/write for co-founders via OIDC
# =============================================================================

resource "vault_policy" "seven30_developer" {
  name   = "seven30-developer"
  policy = <<-EOT
    # Vault/OpenBao Terraform provider creates limited child tokens per resource
    path "auth/token/create" {
      capabilities = ["update"]
    }

    # Seven30 developers can manage their own secrets
    path "kv/data/seven30/*" {
      capabilities = ["create", "read", "update", "delete"]
    }

    path "kv/metadata/seven30/*" {
      capabilities = ["read", "list", "delete"]
    }

    path "kv/delete/seven30/*" {
      capabilities = ["update"]
    }

    # CI manages seven30's own transit/secrets mounts
    path "sys/mounts/seven30/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }

    # SOPS transit encryption
    # Transit encryption (all mounts under seven30/)
    path "seven30/+/keys/*" {
      capabilities = ["create", "read", "update", "list"]
    }

    path "seven30/+/keys" {
      capabilities = ["list"]
    }

    path "seven30/+/encrypt/*" {
      capabilities = ["update"]
    }

    path "seven30/+/decrypt/*" {
      capabilities = ["update"]
    }
  EOT
}

# OIDC role — browser-based login (bao UI / bao login -method=oidc)
resource "vault_jwt_auth_backend_role" "seven30_developer" {
  backend        = vault_jwt_auth_backend.keycloak.path
  role_name      = "seven30-developer"
  role_type      = "oidc"
  token_policies = ["default", vault_policy.seven30_developer.name]

  user_claim   = "preferred_username"
  bound_claims = { "roles" = "admin,seven30-developer" }
  oidc_scopes  = ["openid", "profile", "email"]
  allowed_redirect_uris = [
    "https://bao.home.shdr.ch/ui/vault/auth/oidc/oidc/callback",
    "https://bao.home.shdr.ch/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
}

# CLI role — token exchange (task bao:login style)
resource "vault_jwt_auth_backend_role" "cli_seven30_developer" {
  backend        = vault_jwt_auth_backend.jwt.path
  role_name      = "cli-seven30-developer"
  role_type      = "jwt"
  token_policies = ["default", vault_policy.seven30_developer.name]

  user_claim   = "preferred_username"
  bound_claims = { "roles" = "admin,seven30-developer" }
  bound_audiences = [
    keycloak_openid_client.toolbox.client_id,
    keycloak_openid_client.openbao.client_id,
  ]
}

# =============================================================================
# JWT Auth Backend — trusts GitLab CI OIDC tokens
# =============================================================================
# Enables seven30/* GitLab CI to authenticate with OpenBao using
# short-lived OIDC tokens (id_tokens). Used for:
#   - SOPS Transit decryption (data "sops_file" in Tofu)
#   - Writing app secrets to kv/data/seven30/* (vault_kv_secret_v2 in Tofu)

resource "vault_jwt_auth_backend" "gitlab" {
  path               = "jwt-gitlab"
  type               = "jwt"
  oidc_discovery_url = "https://gitlab.home.shdr.ch"
  default_role       = "seven30-ci"

  tune {
    default_lease_ttl = "30m"
    max_lease_ttl     = "1h"
    token_type        = "default-service"
  }
}

# =============================================================================
# Role: seven30-ci — for GitLab CI to decrypt SOPS + write KV secrets
# =============================================================================

resource "vault_jwt_auth_backend_role" "gitlab_seven30_ci" {
  backend        = vault_jwt_auth_backend.gitlab.path
  role_name      = "seven30-ci"
  role_type      = "jwt"
  token_policies = [vault_policy.seven30_ci.name]
  token_ttl      = 900 # 15 min, enough for tofu apply

  user_claim = "user_email"

  # Any project under the seven30 group can assume this role
  bound_claims_type = "glob"
  bound_claims = {
    "project_path" = "seven30/*"
  }

  bound_audiences = ["https://bao.home.shdr.ch"]
}

# =============================================================================
# Policy: seven30-ci — Transit decrypt + KV write for CI pipeline
# =============================================================================

resource "vault_policy" "seven30_ci" {
  name   = "seven30-ci"
  policy = <<-EOT
    # Vault/OpenBao Terraform provider creates limited child tokens per resource
    path "auth/token/create" {
      capabilities = ["update"]
    }

    path "seven30/sops/decrypt/*" {
      capabilities = ["update"]
    }
    path "seven30/sops/keys/*" {
      capabilities = ["read"]
    }

    # Write seven30 KV secrets (tofu apply seeds OpenBao from SOPS)
    path "kv/data/seven30/*" {
      capabilities = ["create", "read", "update"]
    }
    path "kv/metadata/seven30/*" {
      capabilities = ["create", "read", "update", "list"]
    }

    # CI manages seven30's own transit/secrets mounts
    path "sys/mounts/seven30/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
  EOT
}

# =============================================================================
# Seed Secrets — aether-managed, ESO syncs to K8s
# =============================================================================
# Only secrets that reference aether-managed resources stay here.
# App secrets (OpenClaw, Vaultwarden, etc.) are managed via SOPS in seven30/infra.

resource "vault_kv_secret_v2" "seven30_crossplane_keycloak" {
  mount = vault_mount.kv.path
  name  = "seven30/crossplane-keycloak"

  data_json = jsonencode({
    client_id     = keycloak_openid_client.seven30_crossplane.client_id
    client_secret = keycloak_openid_client.seven30_crossplane.client_secret
    url           = "https://auth.shdr.ch"
    realm         = "master"
  })
}
