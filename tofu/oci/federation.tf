# Keycloak -> OCI federation (Workload Identity Federation / UPST token-exchange).
#
# Parity with tofu/aws/oidc-identity-provider.tf: the hand-rolled Keycloak realm
# (auth.shdr.ch/realms/aether) is trusted by this Identity Domain to mint OCI User
# Principal Session Tokens (UPST). `login.bb` exchanges the Keycloak JWT it already
# holds for a UPST via the domain's /oauth2/v1/token endpoint - no OCI browser, only
# the existing Keycloak device flow.
#
# BOOTSTRAP (one-time, like AWS needed initial admin keys): the oci provider auths
# with an `oci session authenticate` browser session for the FIRST apply that creates
# these resources. Afterward `task login` federates with no browser.
#
# The finicky fields were pinned by live apply + token-exchange iteration (see the
# comments on allowed_grants, oauth_clients, client_claim_name, and
# subject_mapping_attribute below); everything validates against provider v7.32.0.

variable "keycloak_shdrch_sub" {
  type        = string
  description = "Keycloak subject (sub) of the admin user; the only identity the trust accepts. Same value pinned by tofu/aws."
}

# Tenancy's Identity Domain (the free 'Default' domain) SCIM/OAuth endpoint.
data "oci_identity_domains" "estate" {
  compartment_id = var.tenancy_ocid
}

locals {
  oci_domain_url = one([for d in data.oci_identity_domains.estate.domains : d.url if d.display_name == "Default"])
}

# Dedicated federated-admin principal (not the console user). Its userName IS the
# Keycloak sub, so the trust maps token.sub -> this user 1:1 via userName (a supported
# subject_mapping_attribute). external_id also carries the sub. A no-login service
# email is set because an emails block is required to create the user.
resource "oci_identity_domains_user" "federated_admin" {
  idcs_endpoint = local.oci_domain_url
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:User"]
  user_name     = var.keycloak_shdrch_sub
  external_id   = var.keycloak_shdrch_sub

  name {
    family_name = "Federation"
    given_name  = "Aether"
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

resource "oci_identity_domains_group" "federated_admins" {
  idcs_endpoint = local.oci_domain_url
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:Group"]
  display_name  = "aether-federated-admins"

  members {
    type  = "User"
    value = oci_identity_domains_user.federated_admin.id
  }

  lifecycle { ignore_changes = [schemas, members] }
}

# Admin for the federated group (parallel to the AWS AdministratorAccess attach).
# Domain-qualified group name: '<domain>'/'<group>'.
resource "oci_identity_policy" "federated_admins" {
  compartment_id = var.tenancy_ocid
  name           = "aether-federated-admins"
  description    = "Admin access for Keycloak-federated CLI principals"

  statements = [
    "Allow group 'Default'/'aether-federated-admins' to manage all-resources in tenancy",
  ]
}

# Confidential OAuth client: its client_id/secret do Basic auth on the token-exchange
# request. based_on_template CustomWebAppTemplateId per provider docs/example. Both
# client_id (name) and client_secret are server-generated (computed) - TF captures
# them from the create response into state, which the outputs below re-export.
resource "oci_identity_domains_app" "token_exchange" {
  idcs_endpoint = local.oci_domain_url
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]

  based_on_template {
    value = "CustomWebAppTemplateId"
  }

  display_name    = "aether-token-exchange"
  description     = "Confidential client for Keycloak->OCI UPST token-exchange"
  client_type     = "confidential"
  is_oauth_client = true
  active          = true

  # Measured: OCI clamps UPST lifetime to ~60 min server-side - a trial value of
  # 43200 here still produced a 59-min UPST (exp-iat), so longer OCI sessions come
  # from re-minting via the Keycloak refresh token, not from this field. Pinned to
  # the IDCS default (3600) explicitly; it governs only ordinary OAuth access
  # tokens for this client, which should stay short.
  access_token_expiry = 3600

  # client_credentials is sufficient: it authenticates the app for the Basic-auth
  # header on /oauth2/v1/token; authorization to *invoke the exchange* comes from
  # the trust's oauth_clients list, not a grant enum. ("token-exchange"/"jwt-bearer"
  # are not valid allowed_grants values - IDCS 400s on them.)
  allowed_grants = ["client_credentials"]

  lifecycle { ignore_changes = [schemas] }
}

# The trust: accept Keycloak JWTs (issuer + azp=toolbox), map the sub claim to the
# dedicated user via userName. No impersonation.
resource "oci_identity_domains_identity_propagation_trust" "keycloak" {
  idcs_endpoint = local.oci_domain_url
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:IdentityPropagationTrust"]
  name          = "keycloak-toolbox"
  type          = "JWT"
  active        = true

  # UPST is issued AS the mapped user (subject mapping below); impersonation off.
  allow_impersonation = false

  issuer              = "https://auth.shdr.ch/realms/aether"
  public_key_endpoint = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/certs"

  # Incoming JWT must be issued to the toolbox client. Keycloak's azp (authorized
  # party) is a single string; aud is an array ["toolbox","openbao"], which IDCS's
  # claim matcher appears unable to handle (opaque 500 "remove" = immutable-list
  # mutation server-side). azp avoids the array entirely.
  client_claim_name   = "azp"
  client_claim_values = ["toolbox"]

  # oauth_clients = the OCI OAuth client allowed to invoke this trust's exchange
  # (the confidential app above, by its client_id == app.name), NOT the Keycloak
  # audience. Verified live.
  oauth_clients = [oci_identity_domains_app.token_exchange.name]

  # Map JWT sub -> the dedicated user's userName (== keycloak_shdrch_sub). userName
  # is a supported subject_mapping_attribute; externalId is NOT (IDCS 500s at runtime).
  subject_type              = "User"
  subject_claim_name        = "sub"
  subject_mapping_attribute = "userName"

  lifecycle { ignore_changes = [schemas] }
}

# --- Outputs (re-exported at root outputs.tf, consumed by login.bb via tf-outputs) ---
output "domain_url" {
  value       = local.oci_domain_url
  description = "Identity Domain OAuth/SCIM base URL (for the token-exchange endpoint)"
}

output "tokenexchange_client_id" {
  # The app's `name` attribute IS the OAuth client_id (32-char GUID; verified live).
  value       = oci_identity_domains_app.token_exchange.name
  description = "Confidential app client_id for the UPST token-exchange Basic auth"
}

output "tokenexchange_client_secret" {
  # Computed from the app create response and captured in state (verified: IDCS
  # returned the secret at create; readback populated the tf-output).
  value       = oci_identity_domains_app.token_exchange.client_secret
  sensitive   = true
  description = "Confidential app client_secret for the UPST token-exchange Basic auth"
}
