data "sops_file" "secrets" {
  source_file = "../secrets/secrets.yml"
}

data "local_file" "authorized_keys" {
  filename = "../config/authorized_keys"
}

resource "tls_private_key" "home_dev_workstation_ssh_key" {
  algorithm = "ED25519"
}

locals {
  base_authorized_keys = [
    for key in split("\n", trimspace(data.local_file.authorized_keys.content))
    : key
    if key != "" && !startswith(key, "#")
  ]

  authorized_keys = concat(
    [tls_private_key.home_dev_workstation_ssh_key.public_key_openssh],
    local.base_authorized_keys
  )

  aws_notification_email = data.sops_file.secrets.data["aws_notification_email"]

  home = {
    proxmox = {
      endpoint = data.sops_file.secrets.data["proxmox.cluster_endpoint"]
      username = data.sops_file.secrets.data["proxmox.cluster_username"]
      password = data.sops_file.secrets.data["proxmox.cluster_password"]
    }
    router_password  = data.sops_file.secrets.data["router_password"]
    desktop_password = data.sops_file.secrets.data["desktop_password"]
    dev_workstation = {
      private_key = tls_private_key.home_dev_workstation_ssh_key.private_key_openssh
      public_key  = tls_private_key.home_dev_workstation_ssh_key.public_key_openssh
    }
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy to"
}

variable "aws_iac_role_arn" {
  type        = string
  description = "ARN of the IAC role to assume"
}

