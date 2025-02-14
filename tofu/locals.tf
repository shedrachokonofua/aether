locals {
  proxmox = {
    endpoint = data.sops_file.proxmox_secrets.data.cluster_endpoint
    username = data.sops_file.proxmox_secrets.data.cluster_username
    password = data.sops_file.proxmox_secrets.data.cluster_password
  }
  vm_pass = 2705
}
