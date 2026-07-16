terraform {
  backend "s3" {
    encrypt = true
    region  = var.aws_region
  }

  required_providers {
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.4"
    }

    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.20"
    }

    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }

    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}

module "aws" {
  source                 = "./aws"
  aws_region             = var.aws_region
  aws_notification_email = local.aws.notification_email
  keycloak_shdrch_sub    = module.home.keycloak_shdrch_user_id
}

module "google" {
  count                 = local.google.project_id != "" ? 1 : 0
  source                = "./google"
  project_id            = local.google.project_id
  keycloak_shdrch_email = local.home.keycloak.shdrch_email
  billing_account_id    = local.google.billing_account_id
}

provider "google" {
  project               = local.google.project_id != "" ? local.google.project_id : null
  user_project_override = true
}

# OCI uses keyless session-token auth (profile oci-aether from `oci session
# authenticate` now, `task login` UPST later). Configured lazily; when the oci
# module is count=0 (no tenancy set) this provider is never initialized.
provider "oci" {
  auth                = "SecurityToken"
  config_file_profile = "oci-aether"
  region              = "ca-toronto-1"
}

# Gated on secrets["oci.tenancy_ocid"]: inert until the tenancy OCID is added to
# SOPS, exactly like module.google gates on project_id.
module "oci" {
  count               = local.oci.tenancy_ocid != "" ? 1 : 0
  source              = "./oci"
  tenancy_ocid        = local.oci.tenancy_ocid
  keycloak_shdrch_sub = module.home.keycloak_shdrch_user_id
}

provider "cloudflare" {
  api_token = local.cloudflare.api_token
}

provider "cloudflare" {
  alias     = "seven30"
  api_token = local.cloudflare.api_token
}

module "home" {
  source                           = "./home"
  secrets                          = data.sops_file.secrets.data
  authorized_keys                  = local.authorized_keys
  proxmox_endpoint                 = local.home.proxmox.endpoint
  proxmox_username                 = local.home.proxmox.username
  proxmox_password                 = local.home.proxmox.password
  router_password                  = local.home.router_password
  desktop_password                 = local.home.desktop_password
  keycloak_admin_username          = local.home.keycloak.admin_username
  keycloak_admin_password          = local.home.keycloak.admin_password
  keycloak_shdrch_email            = local.home.keycloak.shdrch_email
  keycloak_shdrch_initial_password = local.home.keycloak.shdrch_initial_password
  litellm_google_maps_api_key      = local.litellm_google_maps_api_key
  litellm_google_maps_enabled      = local.litellm_google_maps_enabled
}

provider "tailscale" {
  tailnet             = local.tailscale.tailnet_name
  oauth_client_id     = local.tailscale.oauth_client_id
  oauth_client_secret = local.tailscale.oauth_client_secret
}
