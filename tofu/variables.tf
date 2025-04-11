data "sops_file" "secrets" {
  source_file = "../secrets/secrets.yml"
}

data "local_file" "authorized_keys" {
  filename = "../config/authorized_keys"
}

locals {
  authorized_keys = [
    for key in split("\n", trimspace(data.local_file.authorized_keys.content))
    : key
    if key != "" && !startswith(key, "#")
  ]

  home = {
    proxmox = {
      endpoint = data.sops_file.secrets.data["proxmox.cluster_endpoint"]
      username = data.sops_file.secrets.data["proxmox.cluster_username"]
      password = data.sops_file.secrets.data["proxmox.cluster_password"]
    }
    router_password  = data.sops_file.secrets.data["router_password"]
    desktop_password = data.sops_file.secrets.data["desktop_password"]
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

