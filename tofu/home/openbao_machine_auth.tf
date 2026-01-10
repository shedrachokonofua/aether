# OpenBao Machine Authentication and Secrets for Aether Homelab
#
# Enables machines to authenticate using step-ca certificates
# and access secrets from the KV secrets engine.
#
# Architecture:
#   - Auth: Any machine with step-ca cert (*.home.shdr.ch) can authenticate
#   - Secrets: SOPS → Terraform → OpenBao KV → machines at runtime
#   - Namespace: kv/aether/* for homelab secrets
#
# Prerequisites:
#   - OpenBao must be initialized and unsealed
#   - step-ca must be running and reachable
#   - Run: task bao:login
#   - Then: task tofu:apply

# =============================================================================
# step-ca Root Certificate
# =============================================================================

data "http" "step_ca_root" {
  url      = "https://ca.shdr.ch/roots.pem"
  insecure = true  # step-ca uses self-signed root
}

# =============================================================================
# Cert Auth Method
# =============================================================================
# Any machine with a step-ca certificate can authenticate.
# Works with NixOS, Fedora, Debian, containers — anything with a cert.

resource "vault_auth_backend" "cert" {
  type        = "cert"
  path        = "cert"
  description = "Machine authentication via step-ca certificates"
  
  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "24h"
  }
}

resource "vault_cert_auth_backend_role" "aether_machine" {
  backend        = vault_auth_backend.cert.path
  name           = "aether-machine"
  certificate    = data.http.step_ca_root.response_body
  token_policies = [vault_policy.aether_secrets.name]
  
  # Any machine with CN *.home.shdr.ch can authenticate
  allowed_common_names = ["*.home.shdr.ch"]
  
  token_ttl     = 3600   # 1 hour
  token_max_ttl = 86400  # 24 hours
}

# =============================================================================
# KV Secrets Engine
# =============================================================================

resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv-v2"
  description = "Key-Value secrets for Aether homelab"
}

# Policy for Aether machines to read secrets
resource "vault_policy" "aether_secrets" {
  name   = "aether-secrets"
  policy = <<-EOT
    # Read all Aether secrets
    path "kv/data/aether/*" {
      capabilities = ["read"]
    }
    
    # List secrets (for debugging)
    path "kv/metadata/aether/*" {
      capabilities = ["list"]
    }
  EOT
}

# =============================================================================
# Aether Secrets (synced from SOPS)
# =============================================================================
# Source of truth: secrets/secrets.yml

resource "vault_kv_secret_v2" "wazuh" {
  mount = vault_mount.kv.path
  name  = "aether/wazuh"
  
  data_json = jsonencode({
    indexer_password   = var.secrets["wazuh.indexer_password"]
    api_password       = var.secrets["wazuh.api_password"]
    dashboard_password = var.secrets["wazuh.dashboard_password"]
  })
}

# =============================================================================
# Outputs
# =============================================================================

output "cert_auth_path" {
  description = "Path to cert auth backend"
  value       = vault_auth_backend.cert.path
}

output "cert_auth_role" {
  description = "Name of the cert auth role for Aether machines"
  value       = vault_cert_auth_backend_role.aether_machine.name
}

output "kv_mount_path" {
  description = "Path to KV secrets engine"
  value       = vault_mount.kv.path
}

output "step_ca_root_cert" {
  description = "step-ca root certificate (PEM format)"
  value       = data.http.step_ca_root.response_body
  sensitive   = true
}
