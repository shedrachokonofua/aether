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
  }
}

provider "cloudflare" {
  api_token = local.cloudflare_api_token
}

module "aws" {
  source           = "./aws"
  aws_region       = var.aws_region
  aws_iac_role_arn = var.aws_iac_role_arn
  aws_notification_email = local.aws_notification_email
}

module "home" {
  source           = "./home"
  authorized_keys  = local.authorized_keys
  proxmox_endpoint = local.home.proxmox.endpoint
  proxmox_username = local.home.proxmox.username
  proxmox_password = local.home.proxmox.password
  router_password  = local.home.router_password
  desktop_password = local.home.desktop_password
}
