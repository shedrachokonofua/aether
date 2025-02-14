data "sops_file" "proxmox_secrets" {
  source_file = "../secrets/proxmox.yaml"
}
