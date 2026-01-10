# step-ca Certificate Module
#
# Requests machine certificates from step-ca during terraform apply.
# Certificates are stored in Terraform state (no files on disk).
#
# Usage:
#   module "ids_stack_cert" {
#     source               = "./modules/step_ca_cert"
#     hostname             = "ids-stack.home.shdr.ch"
#     ip_addresses         = ["10.0.2.7"]
#     provisioner_password = data.sops_file.secrets.data["step_ca.provisioner_password"]
#   }

terraform {
  required_providers {
    external = {
      source = "hashicorp/external"
    }
  }
}

variable "hostname" {
  type        = string
  description = "Hostname for the certificate (CN and primary SAN)"
}

variable "step_ca_url" {
  type        = string
  default     = "https://ca.shdr.ch"
  description = "step-ca server URL"
}

variable "provisioner" {
  type        = string
  default     = "machine-bootstrap"
  description = "step-ca provisioner name"
}

variable "provisioner_password" {
  type        = string
  sensitive   = true
  description = "step-ca provisioner password (from SOPS)"
}

variable "ip_addresses" {
  type        = list(string)
  default     = []
  description = "Additional IP addresses for SANs"
}

variable "dns_names" {
  type        = list(string)
  default     = []
  description = "Additional DNS names for SANs"
}

variable "not_after" {
  type        = string
  default     = "24h"
  description = "Certificate validity duration (max depends on step-ca provisioner config)"
}

# Build SAN arguments
locals {
  san_args = join(" ", concat(
    ["--san=${var.hostname}"],
    [for ip in var.ip_addresses : "--san=${ip}"],
    [for dns in var.dns_names : "--san=${dns}"],
    ["--san=localhost", "--san=127.0.0.1"]
  ))
}

# Request certificate from step-ca
# Output stored in Terraform state, no files left on disk
data "external" "cert" {
  program = ["bash", "-c", <<-EOT
    set -e
    
    # Create temp files
    CERT_FILE=$(mktemp)
    KEY_FILE=$(mktemp)
    trap "rm -f $CERT_FILE $KEY_FILE" EXIT
    
    # Bootstrap step-ca trust (idempotent, errors ignored)
    step ca bootstrap \
      --ca-url="${var.step_ca_url}" \
      --install \
      --force 2>/dev/null || true
    
    # Request certificate
    step ca certificate \
      "${var.hostname}" \
      "$CERT_FILE" \
      "$KEY_FILE" \
      ${local.san_args} \
      --provisioner="${var.provisioner}" \
      --provisioner-password-file=<(echo "${var.provisioner_password}") \
      --not-after="${var.not_after}" \
      --force >&2
    
    # Fetch CA root cert (step-cli handles trust)
    CA_CERT=$(step ca root --ca-url="${var.step_ca_url}")
    
    # Output as JSON (stored in Terraform state)
    jq -n \
      --arg cert "$(cat $CERT_FILE)" \
      --arg key "$(cat $KEY_FILE)" \
      --arg ca_cert "$CA_CERT" \
      '{cert: $cert, key: $key, ca_cert: $ca_cert}'
  EOT
  ]
}

output "cert_pem" {
  description = "Machine certificate (PEM)"
  value       = data.external.cert.result.cert
  sensitive   = true
}

output "key_pem" {
  description = "Private key (PEM)"
  value       = data.external.cert.result.key
  sensitive   = true
}

output "ca_cert_pem" {
  description = "step-ca root certificate (PEM)"
  value       = data.external.cert.result.ca_cert
  sensitive   = true
}

