# cloud-audit — read-only audit access for vigil (PLAN.md §4)
#
# Dedicated read-only Identity Domain user + group and a tenancy policy
# limited to reading audit events. The UPST path rides the EXISTING
# keycloak-toolbox IdentityPropagationTrust (federation.tf): IDCS permits
# exactly one propagation trust per issuer (verified 2026-07-18 — a second
# trust is rejected with "same issuer already exists"), so that trust's
# client_claim_values now admits azp=cloud-audit and maps sub -> this user
# via userName. The exchange is invoked with the existing
# aether-token-exchange app's Basic-auth credentials (Bao kv key
# oci_token_exchange_client_secret).

variable "keycloak_cloud_audit_sub" {
  type        = string
  description = "Keycloak sub of the cloud-audit client's service-account user"
}

# Dedicated read-only principal. userName IS the Keycloak sub so the trust maps
# token.sub -> this user 1:1 (same pattern as federated_admin in federation.tf).
resource "oci_identity_domains_user" "cloud_audit" {
  idcs_endpoint = local.oci_domain_url
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:User"]
  user_name     = var.keycloak_cloud_audit_sub
  external_id   = var.keycloak_cloud_audit_sub

  name {
    family_name = "CloudAudit"
    given_name  = "Vigil"
  }

  emails {
    type    = "work"
    value   = "aether-federation@shdr.ch"
    primary = true
  }
  emails {
    type  = "recovery"
    value = "aether-federation@shdr.ch"
  }

  lifecycle { ignore_changes = [schemas] }
}

resource "oci_identity_domains_group" "cloud_audit_readers" {
  idcs_endpoint = local.oci_domain_url
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:Group"]
  display_name  = "cloud-audit-readers"

  members {
    type  = "User"
    value = oci_identity_domains_user.cloud_audit.id
  }

  lifecycle { ignore_changes = [schemas, members] }
}

resource "oci_identity_policy" "cloud_audit_readers" {
  compartment_id = var.tenancy_ocid
  name           = "cloud-audit-readers"
  description    = "Read-only audit-events access for the vigil forwarder"

  statements = [
    "Allow group 'Default'/'cloud-audit-readers' to read audit-events in tenancy",
  ]
}
