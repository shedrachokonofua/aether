# =============================================================================
# OpenBao — so/* GitLab CI + Inquest/Kestra secrets
# =============================================================================
# Mirrors seven30-ci (openbao_seven30.tf) for projects under the `so` group.
# Inquest CI authenticates via GitLab OIDC → role so-ci → reads kv/aether/*.

resource "vault_policy" "so_ci" {
  name   = "so-ci"
  policy = <<-EOT
    path "auth/token/create" {
      capabilities = ["update"]
    }

    # Read Inquest / Kestra host credentials for flow apply
    path "kv/data/aether/kestra" {
      capabilities = ["read"]
    }
    path "kv/metadata/aether/kestra" {
      capabilities = ["read"]
    }
    path "kv/data/aether/inquest" {
      capabilities = ["read"]
    }
    path "kv/metadata/aether/inquest" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "gitlab_so_ci" {
  backend        = vault_jwt_auth_backend.gitlab.path
  role_name      = "so-ci"
  role_type      = "jwt"
  token_policies = [vault_policy.so_ci.name]
  token_ttl      = 900

  user_claim        = "user_email"
  bound_claims_type = "glob"
  bound_claims = {
    "project_path" = "so/*"
  }
  bound_audiences = ["https://bao.home.shdr.ch"]
}

resource "vault_kv_secret_v2" "kestra" {
  mount = vault_mount.kv.path
  name  = "aether/kestra"

  data_json = jsonencode({
    basic_auth_username = var.secrets["kestra.basic_auth_username"]
    basic_auth_password = var.secrets["kestra.basic_auth_password"]
    url                 = "https://kestra.home.shdr.ch"
  })
}

resource "vault_kv_secret_v2" "inquest" {
  mount = vault_mount.kv.path
  name  = "aether/inquest"

  data_json = jsonencode({
    webhook_key  = var.secrets["inquest.webhook_key"]
    gitlab_token = var.secrets["inquest.gitlab_token"]
    gitlab_url   = "https://gitlab.home.shdr.ch"
    gitlab_project = "so/aether/incidents"
  })
}
