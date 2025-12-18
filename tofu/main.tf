terraform {
  backend "s3" {
    encrypt = true
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
  }
}

module "aws" {
  source                 = "./aws"
  aws_region             = var.aws_region
  aws_iac_role_arn       = var.aws_iac_role_arn
  aws_notification_email = local.aws.notification_email
}

provider "cloudflare" {
  api_token = local.cloudflare.api_token
}

module "home" {
  source                           = "./home"
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
}

provider "tailscale" {
  tailnet             = local.tailscale.tailnet_name
  oauth_client_id     = local.tailscale.oauth_client_id
  oauth_client_secret = local.tailscale.oauth_client_secret
}
