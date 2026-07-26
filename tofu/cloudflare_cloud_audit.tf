# =============================================================================
# Cloudflare — cloud-audit (vigil) API token
# =============================================================================
# Account-scoped Audit Logs Read, nothing else. One of the two irreducibly
# static credentials in the vigil design (Cloudflare has no federation —
# PLAN.md credential inventory). Value flows to Bao via the home module
# (openbao_cloud_audit.tf).
#
# GATED: the tofu CF provider's token is DNS-scoped and cannot manage API
# tokens (403 9109 on plan, verified 2026-07-18). Flip `cloud_audit_cf_enabled`
# once the provider credential gains Account API Tokens Write — or drop the
# resource entirely and wire a dashboard-minted token via SOPS instead.
#
# 2026-07-25 update: the SOPS route was taken — vigil currently shares
# cloudflare_dns_api_key (see tofu/main.tf). NOTE: the permission group below
# is wrong for this endpoint; the account audit_logs API accepts
# "Account Settings Read" (verified against the official API reference).
# Fix the data source name before ever enabling this gate.

locals {
  cloud_audit_cf_enabled = false
}

data "cloudflare_account_api_token_permission_groups" "audit_logs_read" {
  count      = local.cloud_audit_cf_enabled ? 1 : 0
  account_id = local.cloudflare.account_id
  name       = "Account%20Audit%20Logs%20Read"
  scope      = "com.cloudflare.api.account"
}

resource "cloudflare_api_token" "cloud_audit" {
  count = local.cloud_audit_cf_enabled ? 1 : 0
  name  = "cloud-audit (vigil)"

  policies = [{
    effect = "allow"
    permission_groups = [
      { id = one(data.cloudflare_account_api_token_permission_groups.audit_logs_read[0].permission_groups).id },
    ]
    resources = jsonencode({
      "com.cloudflare.api.account.${local.cloudflare.account_id}" = "*"
    })
  }]
}
