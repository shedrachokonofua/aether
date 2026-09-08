# =============================================================================
# OpenBao Auth & Secrets for Attaining
# =============================================================================
# Attaining is the solo studio brand (attain.ing). Unlike Seven30 it has NO
# vcluster: workloads run in host namespaces declared in
# tofu/home/kubernetes/namespace_contracts.tf with tier=guest, owner=attaining,
# and are deployed by the so/attaining/platform repo via the GitLab Agent.
#
# One auth path into OpenBao (contrast openbao_seven30.tf's three):
#   1. JWT (GitLab CI OIDC) — so/attaining/* CI decrypts SOPS + writes KV
#
# There is deliberately no OIDC developer role and no vcluster SA backend:
#   - the operator is already an aether admin, so a second human role would
#     grant nothing it does not already hold
#   - host ESO authenticates per namespace via vault_auth_backend.kubernetes_aether
#     (tofu/home/kubernetes/openbao_kubernetes_auth.tf), which is created
#     for_each namespace_contract_specs — declaring the namespace is the wiring
#
# Secrets pipeline:
#   SOPS (so/attaining/platform) -> GitLab CI -> OpenBao KV -> host ESO -> K8s Secrets

locals {
  attaining_ci_role = "attaining-ci"

  # GitLab group path glob. Matches the trust boundary the group was created at;
  # a group rename invalidates this claim binding (see openbao_seven30.tf:236).
  attaining_project_path = "so/attaining/*"

  # Host-ESO KV prefix. Mirrors local.eso_secret_path_prefix in the kubernetes
  # submodule ("aether/kubernetes"), which is not in scope here. The trailing
  # glob covers every attaining-owned namespace without further tofu changes.
  attaining_eso_path_prefix = "aether/kubernetes/attaining-"
}

# =============================================================================
# Role: attaining-ci — GitLab CI decrypts SOPS + seeds KV
# =============================================================================
# Requested explicitly by name in CI. The shared jwt-gitlab backend defaults to
# seven30-ci (openbao_seven30.tf:214), so a pipeline that omits the role name
# falls back to Seven30's policy rather than failing closed.

resource "vault_jwt_auth_backend_role" "gitlab_attaining_ci" {
  backend        = vault_jwt_auth_backend.gitlab.path
  role_name      = local.attaining_ci_role
  role_type      = "jwt"
  token_policies = [vault_policy.attaining_ci.name]
  token_ttl      = 900 # 15 min, enough for tofu apply

  user_claim = "user_email"

  # Any project under the so/attaining group can assume this role
  bound_claims_type = "glob"
  bound_claims = {
    "project_path" = local.attaining_project_path
  }

  bound_audiences = ["https://bao.home.shdr.ch"]
}

# =============================================================================
# Policy: attaining-ci — Transit decrypt + KV write
# =============================================================================
# Scoped so Attaining CI cannot read kv/data/seven30/* and Seven30 CI cannot
# read Attaining's: secret scope is the sharpest splitter
# (docs/namespace-strategy.md §2 principle 8).

resource "vault_policy" "attaining_ci" {
  name   = "attaining-ci"
  policy = <<-EOT
    # Vault/OpenBao Terraform provider creates limited child tokens per resource
    path "auth/token/create" {
      capabilities = ["update"]
    }

    # SOPS transit encryption (CI creates the mount on first apply)
    path "attaining/+/decrypt/*" {
      capabilities = ["update"]
    }
    path "attaining/+/encrypt/*" {
      capabilities = ["update"]
    }
    path "attaining/+/keys/*" {
      capabilities = ["read"]
    }
    path "attaining/+/keys" {
      capabilities = ["list"]
    }

    # CI manages attaining's own transit/secrets mounts
    path "sys/mounts/attaining/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }

    # Seed the paths host ESO already reads per namespace. The per-namespace
    # reader policy (openbao_kubernetes_auth.tf:33) grants read; CI writes.
    path "${vault_mount.kv.path}/data/${local.attaining_eso_path_prefix}*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "${vault_mount.kv.path}/metadata/${local.attaining_eso_path_prefix}*" {
      capabilities = ["create", "read", "update", "list", "delete"]
    }

    # Repo-level secrets not bound to a single namespace
    path "${vault_mount.kv.path}/data/attaining/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "${vault_mount.kv.path}/metadata/attaining/*" {
      capabilities = ["create", "read", "update", "list", "delete"]
    }
  EOT
}
