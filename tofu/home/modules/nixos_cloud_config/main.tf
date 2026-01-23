# NixOS Cloud Config Module
#
# Requests a machine certificate from step-ca and generates a cloud-config
# snippet for NixOS VMs with machine identity pre-provisioned.
#
# Usage:
#   module "blockchain_stack_cloud_config" {
#     source = "./modules/nixos_cloud_config"
#
#     name                 = "blockchain-stack"
#     ip_addresses         = ["10.0.3.10"]
#     node_name            = "smith"
#     provisioner_password = var.secrets["step_ca.provisioner_password"]
#   }
#
#   # Use in VM initialization:
#   initialization {
#     user_data_file_id = module.blockchain_stack_cloud_config.file_id
#   }

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.71.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "name" {
  type        = string
  description = "Short hostname for the VM (e.g. 'blockchain-stack')"
}

variable "domain" {
  type        = string
  default     = "home.shdr.ch"
  description = "Domain suffix for FQDN"
}

variable "node_name" {
  type        = string
  description = "Proxmox node name to store the snippet"
}

variable "ip_addresses" {
  type        = list(string)
  default     = []
  description = "IP addresses to include in certificate SANs"
}

variable "dns_names" {
  type        = list(string)
  default     = []
  description = "Additional DNS names for certificate SANs"
}

variable "provisioner_password" {
  type        = string
  sensitive   = true
  description = "step-ca provisioner password (from SOPS)"
}

variable "datastore_id" {
  type        = string
  default     = "local"
  description = "Proxmox datastore for snippets"
}

variable "extra_write_files" {
  type = list(object({
    path        = string
    content     = string
    permissions = optional(string, "0644")
    encoding    = optional(string, "b64")
  }))
  default     = []
  description = "Additional files to write via cloud-init"
}

# -----------------------------------------------------------------------------
# Certificate Request (uses existing step_ca_cert module)
# -----------------------------------------------------------------------------

module "cert" {
  source = "../step_ca_cert"

  hostname             = "${var.name}.${var.domain}"
  ip_addresses         = var.ip_addresses
  dns_names            = var.dns_names
  provisioner_password = var.provisioner_password
}

# -----------------------------------------------------------------------------
# Cloud Config Snippet
# -----------------------------------------------------------------------------

locals {
  base_write_files = [
    {
      path        = "/etc/ssl/certs/machine.crt"
      encoding    = "b64"
      content     = base64encode(module.cert.cert_pem)
      permissions = "0644"
    },
    {
      path        = "/etc/ssl/private/machine.key"
      encoding    = "b64"
      content     = base64encode(module.cert.key_pem)
      permissions = "0600"
    },
    {
      path        = "/etc/ssl/certs/step-ca-root.crt"
      encoding    = "b64"
      content     = base64encode(module.cert.ca_cert_pem)
      permissions = "0644"
    }
  ]

  extra_write_files_encoded = [
    for f in var.extra_write_files : {
      path        = f.path
      encoding    = f.encoding
      content     = f.encoding == "b64" ? base64encode(f.content) : f.content
      permissions = f.permissions
    }
  ]

  all_write_files = concat(local.base_write_files, local.extra_write_files_encoded)

  cloud_config = <<-EOF
#cloud-config
hostname: ${var.name}
write_files:
%{for f in local.all_write_files~}
  - path: ${f.path}
    encoding: ${f.encoding}
    content: ${f.content}
    permissions: '${f.permissions}'
%{endfor~}
EOF
}

resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = var.datastore_id
  node_name    = var.node_name

  source_raw {
    file_name = "${var.name}-cloud-config.yml"
    data      = local.cloud_config
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "file_id" {
  description = "Cloud config file ID for VM initialization"
  value       = proxmox_virtual_environment_file.cloud_config.id
}

output "cert_pem" {
  description = "Machine certificate (PEM)"
  value       = module.cert.cert_pem
  sensitive   = true
}

output "key_pem" {
  description = "Private key (PEM)"
  value       = module.cert.key_pem
  sensitive   = true
}

output "ca_cert_pem" {
  description = "step-ca root certificate (PEM)"
  value       = module.cert.ca_cert_pem
  sensitive   = true
}
