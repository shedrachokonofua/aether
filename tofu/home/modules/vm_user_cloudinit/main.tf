variable "username" {
  type    = string
  default = "aether"
}

variable "node_name" {
  type = string
}

variable "file_prefix" {
  type = string
}

variable "authorized_keys" {
  type = list(string)
}

variable "console_password" {
  type      = string
  sensitive = true
}

variable "snippet_datastore" {
  type    = string
  default = "cephfs"
}

variable "snippet_node" {
  type    = string
  default = "smith"
}

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.71.0"
    }
  }
}

locals {
  user_data_file_yaml = {
    users = [
      {
        name              = var.username
        plain_text_passwd = var.console_password
        lock_passwd       = false
        chpasswd = {
          expire = false
        }
        ssh_pwauth          = false
        groups              = ["sudo"]
        shell               = "/bin/bash"
        ssh_authorized_keys = var.authorized_keys
        sudo                = "ALL=(ALL) NOPASSWD:ALL"
      }
    ]
  }
}

resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = var.snippet_datastore
  node_name    = var.snippet_datastore == "cephfs" ? var.snippet_node : var.node_name

  source_raw {
    file_name = "${var.file_prefix}-cloud-config.yml"
    data      = <<EOF
#cloud-config
${yamlencode(local.user_data_file_yaml)}
    EOF
  }
}

output "cloud_config_id" {
  value = proxmox_virtual_environment_file.cloud_config.id
}
