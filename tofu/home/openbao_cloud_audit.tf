# =============================================================================
# OpenBao auth & secrets for cloud-audit (vigil)
# =============================================================================
# The vigil pod logs in with its projected ServiceAccount token (audience
# https://bao.home.shdr.ch) and reads the Tailscale/Cloudflare tokens and the
# OCI token-exchange app secret into memory — once per loop iteration, never
# to disk, never to etcd, every read in the Bao audit log. Revocation is a
# policy edit. Clone of the seven30 JWT pattern (openbao_seven30.tf).

# JWT backend trusting the aether cluster SA issuer (anonymous JWKS via the
# Caddy gateway + oidc_discovery_public binding — same trust root as the
# Keycloak leg).
resource "vault_jwt_auth_backend" "cloud_audit" {
  path         = "jwt-cloud-audit"
  type         = "jwt"
  jwks_url     = "https://oidc.k8s.home.shdr.ch/openid/v1/jwks"
  bound_issuer = "https://oidc.k8s.home.shdr.ch"

  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "4h"
    token_type        = "default-service"
  }
}

resource "vault_policy" "cloud_audit" {
  name   = "cloud-audit-read"
  policy = <<-EOT
    # Read the cloud-audit tokens (kv v2). Nothing else.
    path "kv/data/aether/cloud-audit" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "cloud_audit" {
  backend   = vault_jwt_auth_backend.cloud_audit.path
  role_name = "cloud-audit"
  role_type = "jwt"

  token_policies = [vault_policy.cloud_audit.name]
  token_ttl      = 3600 # 1 hour

  user_claim = "sub"

  # Only the vigil SA, only tokens minted for OpenBao.
  bound_claims = {
    "sub" = "system:serviceaccount:cloud-audit:vigil"
  }
  bound_audiences = ["https://bao.home.shdr.ch"]
}

# The secret values land here via tofu (SOPS/provider outputs -> this resource),
# never via a k8s Secret. Keys are the contract vigil's config documents.
resource "vault_kv_secret_v2" "cloud_audit" {
  mount = vault_mount.kv.path
  name  = "aether/cloud-audit"

  data_json = jsonencode({
    tailscale_client_id              = var.cloud_audit_tailscale_client_id
    tailscale_client_secret          = var.cloud_audit_tailscale_client_secret
    cloudflare_api_token             = var.cloud_audit_cloudflare_api_token
    oci_token_exchange_client_id     = var.cloud_audit_oci_token_exchange_client_id
    oci_token_exchange_client_secret = var.cloud_audit_oci_token_exchange_client_secret
  })
}
