terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.71.0" # x-release-please-version
    }

    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "proxmox" {
  endpoint = local.proxmox.endpoint
  username = local.proxmox.username
  password = local.proxmox.password
  insecure = true
}

provider "aws" {
  region = var.AWS_REGION

  assume_role {
    role_arn = var.AWS_IAC_ROLE_ARN
  }
}

variable "AWS_REGION" {
  type        = string
  description = "AWS region to deploy to"
}

variable "AWS_IAC_ROLE_ARN" {
  type        = string
  description = "ARN of the IAC role to assume"
}

