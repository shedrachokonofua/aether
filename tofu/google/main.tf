terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Google Cloud project ID used for Maps Platform APIs"
}

variable "keycloak_shdrch_email" {
  type        = string
  description = "Keycloak email claim allowed to exchange toolbox tokens for Google credentials"
}

variable "litellm_google_maps_allowed_ips" {
  type        = set(string)
  description = "Optional server IP restrictions for the LiteLLM Google Maps MCP API key"
  default     = []
}

locals {
  google_maps_api_targets = [
    "places.googleapis.com",
    "places-backend.googleapis.com",
    "routes.googleapis.com",
    "directions-backend.googleapis.com",
    "geocoding-backend.googleapis.com",
    "distance-matrix-backend.googleapis.com",
    "elevation-backend.googleapis.com",
    "timezone-backend.googleapis.com",
    "static-maps-backend.googleapis.com",
    "airquality.googleapis.com",
    "weather.googleapis.com",
  ]

  google_foundation_services = [
    "apikeys.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "sts.googleapis.com",
    "compute.googleapis.com",
    "osconfig.googleapis.com",
  ]

  google_project_services = toset(concat(local.google_foundation_services, local.google_maps_api_targets))

  google_tofu_project_roles = toset([
    "roles/iam.serviceAccountAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.apiKeysAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/serviceusage.serviceUsageViewer",
    "roles/compute.admin",
    "roles/iam.serviceAccountUser",
  ])
}

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_project_service" "maps" {
  for_each = local.google_project_services

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "tofu" {
  project      = var.project_id
  account_id   = "aether-tofu"
  display_name = "Aether OpenTofu"
  description  = "Impersonated by Keycloak toolbox tokens through Workload Identity Federation"

  depends_on = [google_project_service.maps["iam.googleapis.com"]]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_member" "tofu" {
  for_each = local.google_tofu_project_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.tofu.email}"
}

resource "google_iam_workload_identity_pool" "aether" {
  project                   = var.project_id
  workload_identity_pool_id = "aether"
  display_name              = "Aether"
  description               = "Trusts Aether Keycloak toolbox tokens for keyless OpenTofu access"

  depends_on = [google_project_service.maps["iam.googleapis.com"]]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_iam_workload_identity_pool_provider" "keycloak" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.aether.workload_identity_pool_id
  workload_identity_pool_provider_id = "keycloak"
  display_name                       = "Keycloak"
  description                        = "Aether Keycloak toolbox OIDC tokens"

  attribute_mapping = {
    "google.subject"  = "assertion.sub"
    "attribute.email" = "assertion.email"
  }

  attribute_condition = "assertion.email == \"${var.keycloak_shdrch_email}\""

  oidc {
    issuer_uri        = "https://auth.shdr.ch/realms/aether"
    allowed_audiences = ["toolbox"]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "tofu_workload_identity_user" {
  service_account_id = google_service_account.tofu.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.aether.workload_identity_pool_id}/attribute.email/${var.keycloak_shdrch_email}"
}

resource "google_apikeys_key" "litellm_google_maps" {
  name         = "litellm-google-maps-mcp"
  display_name = "LiteLLM Google Maps MCP"
  project      = var.project_id

  restrictions {
    dynamic "api_targets" {
      for_each = toset(local.google_maps_api_targets)

      content {
        service = api_targets.value
      }
    }

    dynamic "server_key_restrictions" {
      for_each = length(var.litellm_google_maps_allowed_ips) > 0 ? [1] : []

      content {
        allowed_ips = sort(tolist(var.litellm_google_maps_allowed_ips))
      }
    }
  }

  depends_on = [google_project_service.maps]

  lifecycle {
    prevent_destroy = true
  }
}

output "litellm_google_maps_api_key" {
  description = "Google Maps API key used by the LiteLLM Google Maps MCP sidecar"
  value       = google_apikeys_key.litellm_google_maps.key_string
  sensitive   = true
}

output "workload_identity_provider_audience" {
  description = "Audience string used by external-account credentials for Keycloak WIF"
  value       = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.keycloak.name}"
}

output "tofu_service_account_email" {
  description = "Google service account impersonated by task login through WIF"
  value       = google_service_account.tofu.email
}
