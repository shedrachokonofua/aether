# cloud-audit — read-only logging access for vigil (PLAN.md §3)
#
# Sibling WIF provider in the existing pool (does not touch the toolbox
# provider's audiences or the aether-tofu binding), a dedicated SA with only
# roles/logging.viewer, and impersonation scoped to the cloud-audit sub only.

variable "keycloak_cloud_audit_sub" {
  type        = string
  description = "Keycloak sub of the cloud-audit client's service-account user"
}

resource "google_service_account" "cloud_audit" {
  project      = var.project_id
  account_id   = "cloud-audit"
  display_name = "Cloud Audit (vigil)"
  description  = "Read-only audit-log access for the vigil forwarder"
}

resource "google_project_iam_member" "cloud_audit_logging_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${google_service_account.cloud_audit.email}"
}

# Sibling provider: accepts only aud=cloud-audit tokens and only the
# cloud-audit sub. The existing `keycloak` provider (aud=toolbox, email
# condition) is untouched.
resource "google_iam_workload_identity_pool_provider" "cloud_audit" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.aether.workload_identity_pool_id
  workload_identity_pool_provider_id = "cloud-audit"
  display_name                       = "Keycloak cloud-audit"
  description                        = "Aether Keycloak tokens with aud=cloud-audit for the vigil forwarder"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  attribute_condition = "assertion.sub == \"${var.keycloak_cloud_audit_sub}\""

  oidc {
    issuer_uri        = "https://auth.shdr.ch/realms/aether"
    allowed_audiences = ["cloud-audit"]
  }
}

# Impersonation: the cloud-audit subject, and nothing else, may act as this SA.
resource "google_service_account_iam_member" "cloud_audit_workload_identity_user" {
  service_account_id = google_service_account.cloud_audit.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.aether.workload_identity_pool_id}/subject/${var.keycloak_cloud_audit_sub}"
}

output "cloud_audit_service_account_email" {
  value       = google_service_account.cloud_audit.email
  description = "SA vigil impersonates after the WIF STS exchange (vigil [gcp] service_account)"
}

output "cloud_audit_wif_provider" {
  value       = google_iam_workload_identity_pool_provider.cloud_audit.name
  description = "WIF provider resource for the vigil [gcp] workload_identity_provider config"
}
