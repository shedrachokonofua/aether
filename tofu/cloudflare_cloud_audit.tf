# =============================================================================
# Cloudflare — cloud-audit (vigil) API token
# =============================================================================
# Account-scoped Audit Logs Read, nothing else. One of the two irreducibly
# static credentials in the vigil design (Cloudflare has no federation —
# PLAN.md credential inventory). Value flows to Bao via the home module
# (openbao_cloud_audit.tf); set a TTL and rotate via this resource.

data "cloudflare_account_api_token_permission_groups" "audit_logs_read" {
  account_id = local.cloudflare.account_id
  name       = "Account%20Audit%20Logs%20Read"
  scope      = "com.cloudflare.api.account"
}

resource "cloudflare_api_token" "cloud_audit" {
  name = "cloud-audit (vigil)"

  policies = [{
    effect = "allow"
    permission_groups = [
      { id = one(data.cloudflare_account_api_token_permission_groups.audit_logs_read.permission_groups).id },
    ]
    resources = jsonencode({
      "com.cloudflare.api.account.${local.cloudflare.account_id}" = "*"
    })
  }]
}
