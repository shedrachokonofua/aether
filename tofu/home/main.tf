variable "proxmox_endpoint" {
  type = string
}

variable "proxmox_username" {
  type = string
}

variable "proxmox_password" {
  type = string
}

variable "router_password" {
  type = string
}

variable "desktop_password" {
  type = string
}

variable "authorized_keys" {
  type = list(string)
}

variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}

variable "keycloak_admin_username" {
  type    = string
  default = "admin"
}

variable "keycloak_shdrch_email" {
  type = string
}

variable "keycloak_shdrch_initial_password" {
  type      = string
  sensitive = true
}

variable "secrets" {
  type        = map(string)
  sensitive   = true
  description = "SOPS secrets map passed from root module"
}


locals {
  vm = yamldecode(file("${path.module}/../../config/vm.yml"))
}

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.71.0"
    }

    keycloak = {
      source  = "keycloak/keycloak"
      version = ">= 5.5.0"
    }

    vault = {
      source  = "hashicorp/vault"
      version = ">= 4.0.0"
    }

    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true
}

# OpenBao provider (Vault-compatible)
# Requires: task bao:login (token cached), then export VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token)
provider "vault" {
  address = "https://bao.home.shdr.ch"
}
