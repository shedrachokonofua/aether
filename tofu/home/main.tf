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

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.0.1"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.18.0"
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

provider "kubernetes" {
  host                   = try(talos_cluster_kubeconfig.this.kubernetes_client_configuration.host, null)
  client_certificate     = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate), null)
  client_key             = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key), null)
  cluster_ca_certificate = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate), null)
}

provider "helm" {
  kubernetes = {
    host                   = try(talos_cluster_kubeconfig.this.kubernetes_client_configuration.host, null)
    client_certificate     = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate), null)
    client_key             = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key), null)
    cluster_ca_certificate = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate), null)
  }
}

provider "kubectl" {
  host                   = try(talos_cluster_kubeconfig.this.kubernetes_client_configuration.host, null)
  client_certificate     = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate), null)
  client_key             = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key), null)
  cluster_ca_certificate = try(base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate), null)
  load_config_file       = false
}
