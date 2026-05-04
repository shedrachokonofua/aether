# =============================================================================
# Kubernetes Workloads Module
# =============================================================================
# Platform components deployed to the Talos cluster after bootstrap.
#
# This module manages:
#   - Cilium CNI (networking, L2 announcements, Gateway API)
#   - cert-manager + step-issuer + istio-csr (certificate management via step-ca)
#   - Istio Ambient (service mesh, CA delegated to cert-manager)
#   - Gateway API (ingress)
#   - Ceph CSI (storage)
#   - Knative Serving (serverless)
#   - OTEL Collectors (observability)
#   - Metrics Server (resource metrics API)
#   - Kyverno (policy guardrails)
#   - Headlamp (dashboard)
#   - GitLab Agent (CI/CD deployments)
#   - Crossplane (infrastructure control plane)

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.11.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

variable "cluster_name" {
  type        = string
  description = "Kubernetes cluster name"
}

variable "api_vip" {
  type        = string
  description = "Talos API VIP for k8s service host"
}

variable "workload_vip" {
  type        = string
  description = "Cilium L2 VIP for LoadBalancer services"
}

variable "vcluster_vip" {
  type        = string
  description = "Cilium L2 VIP for Seven30 vcluster API server"
}

variable "oidc_issuer_url" {
  type        = string
  description = "OIDC issuer URL for authentication"
}

variable "oidc_client_id" {
  type        = string
  description = "OIDC client ID"
}

variable "gateway_api_version" {
  type        = string
  description = "Gateway API CRD version"
}

variable "kubeconfig_raw" {
  type        = string
  sensitive   = true
  description = "Raw kubeconfig for kubectl commands"
}

variable "secrets" {
  type        = map(string)
  sensitive   = true
  description = "SOPS secrets map (for Ceph credentials)"
}

# =============================================================================
# Crossplane Keycloak Provider
# =============================================================================

variable "keycloak_url" {
  type        = string
  description = "Keycloak base URL for Crossplane provider"
}

variable "keycloak_client_id" {
  type        = string
  description = "Keycloak service account client ID for Crossplane"
}

variable "keycloak_client_secret" {
  type        = string
  sensitive   = true
  description = "Keycloak service account client secret for Crossplane"
}

# =============================================================================
# OpenWebUI OIDC
# =============================================================================

variable "openwebui_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "OpenWebUI Keycloak OIDC client secret"
}

variable "immich_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Immich Keycloak OIDC client secret"
}

variable "nextcloud_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Nextcloud Keycloak OIDC client secret (registered as user_oidc provider after install)"
}

variable "litellm_mcp_url" {
  type        = string
  description = "LiteLLM MCP endpoint URL used by MCPO"
}

variable "coder_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Coder Keycloak OIDC client secret"
}

variable "affine_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "AFFiNE Keycloak OIDC client secret"
}

variable "karakeep_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Karakeep Keycloak OIDC client secret"
}

variable "memos_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Memos Keycloak OIDC client secret (consumed by bootstrap Job — Memos has no OIDC env vars)"
}

variable "nextexplorer_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "nextExplorer Keycloak OIDC client secret"
}

# =============================================================================
# NFS Storage
# =============================================================================

variable "nfs_server_ip" {
  type        = string
  description = "NFS server IP (smith NFS LXC on vyos network)"
}

# =============================================================================
# Media Stack
# =============================================================================

variable "rotating_proxy_addr" {
  type        = string
  description = "SOCKS5 rotating proxy address for tuliprox (host:port)"
}

# =============================================================================
# Shared Locals
# =============================================================================

locals {
  # Cilium creates a service for the Gateway
  cilium_gateway_service = "cilium-gateway-main-gateway.default.svc.cluster.local"
}
