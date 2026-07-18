# cloud-audit — read-only audit access for vigil (PLAN.md §4)
#
# Dedicated read-only Identity Domain user + group, tenancy policy limited to
# reading audit events, and a second IdentityPropagationTrust mapping the
# cloud-audit client's sub (azp=cloud-audit) to that user. The existing
# confidential token-exchange app is reused: its oauth_clients list is
# per-trust, and one app may front multiple trusts (verified in the original
# federation work; see federation.tf comments for the pinned fields).
#
# NOTE: the UPST exchange itself requires the app's Basic-auth client secret
# (federation.tf lines on allowed_grants). vigil reads that secret from Bao at
# runtime (kv/aether/cloud-audit#oci_token_exchange_client_secret); PLAN.md's
# credential inventory is amended accordingly.

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

# Second trust, cloned pinned fields from the toolbox trust (federation.tf):
# azp claim (avoids the aud-array matcher problem documented there), no
# impersonation, same confidential app in oauth_clients, userName mapping.
resource "oci_identity_domains_identity_propagation_trust" "cloud_audit" {
  idcs_endpoint = local.oci_domain_url
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:IdentityPropagationTrust"]
  name          = "keycloak-cloud-audit"
  type          = "JWT"
  active        = true

  allow_impersonation = false

  issuer              = "https://auth.shdr.ch/realms/aether"
  public_key_endpoint = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/certs"

  # Keycloak issues azp = the requesting client; cloud-audit tokens carry
  # azp=cloud-audit. Single string — sidesteps IDCS's aud-array matcher.
  client_claim_name   = "azp"
  client_claim_values = ["cloud-audit"]

  # One confidential app may front multiple trusts (oauth_clients is
  # per-trust). Reusing aether-token-exchange from federation.tf.
  oauth_clients = [oci_identity_domains_app.token_exchange.name]

  # Map JWT sub -> the read-only user's userName (== keycloak_cloud_audit_sub).
  # externalId is NOT a supported mapping attribute (IDCS 500s); userName is.
  subject_type              = "User"
  subject_claim_name        = "sub"
  subject_mapping_attribute = "userName"

  lifecycle { ignore_changes = [schemas] }
}
