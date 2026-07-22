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

variable "litellm_google_maps_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Google Maps API key for LiteLLM's Google Maps MCP server"
}

variable "cloud_audit_tailscale_client_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Tailscale OAuth client id for vigil (cloud_audit.tf)"
}

variable "cloud_audit_tailscale_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Tailscale OAuth client secret for vigil (cloud_audit.tf)"
}

variable "cloud_audit_cloudflare_api_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Cloudflare Audit-Logs-Read token for vigil (cloud_audit.tf)"
}

variable "cloud_audit_oci_token_exchange_client_id" {
  type        = string
  sensitive   = false # client ids are not secrets; kept with the secret for convenience
  default     = ""
  description = "OCI token-exchange app client id for the UPST exchange (oci/federation.tf output)"
}

variable "cloud_audit_oci_token_exchange_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "OCI token-exchange app client secret for the UPST exchange (oci/federation.tf output)"
}

variable "cloud_audit_aws_role_arn" {
  type        = string
  default     = ""
  description = "AWS role vigil assumes (module.aws.cloud_audit_role_arn)"
}

variable "cloud_audit_aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for vigil's signed calls"
}

variable "cloud_audit_gcp_wif_provider" {
  type        = string
  default     = ""
  description = "GCP WIF provider resource name for vigil (module.google cloud_audit_wif_provider)"
}

variable "cloud_audit_gcp_service_account" {
  type        = string
  default     = ""
  description = "GCP service account vigil impersonates (module.google cloud_audit_service_account_email)"
}

variable "cloud_audit_gcp_project_id" {
  type        = string
  default     = ""
  description = "GCP project for vigil's logging reads"
}

variable "cloud_audit_oci_domain_url" {
  type        = string
  default     = ""
  description = "OCI Identity Domain base URL (module.oci domain_url)"
}

variable "cloud_audit_oci_tenancy_ocid" {
  type        = string
  default     = ""
  description = "OCI tenancy OCID (audit compartment)"
}

variable "cloud_audit_tailnet" {
  type        = string
  default     = ""
  description = "Tailscale tailnet name for vigil's state differ"
}

variable "cloud_audit_cloudflare_account_id" {
  type        = string
  default     = ""
  description = "Cloudflare account id for vigil's audit-log reads"
}

variable "litellm_google_maps_enabled" {
  type        = bool
  default     = false
  description = "Whether to deploy LiteLLM's Google Maps MCP server"
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

    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
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
