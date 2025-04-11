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

locals {
  vm = yamldecode(file("${path.module}/../../config/vm.yml"))
}

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.71.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true
}
