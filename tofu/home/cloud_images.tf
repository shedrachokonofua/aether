# =============================================================================
# Downloaded Images (managed by Terraform)
# =============================================================================

resource "proxmox_virtual_environment_download_file" "oracle_fedora_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "oracle"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name    = "fedora-41.qcow2.img"
}

resource "proxmox_virtual_environment_download_file" "niobe_fedora_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "niobe"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name    = "fedora-41.qcow2.img"
}

resource "proxmox_virtual_environment_download_file" "neo_fedora_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "neo"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name    = "fedora-41.qcow2.img"
}

resource "proxmox_virtual_environment_download_file" "fedora_image" {
  content_type = "iso"
  datastore_id = "cephfs"
  node_name    = "smith"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name    = "fedora-41.qcow2.img"
}

resource "proxmox_virtual_environment_download_file" "debian_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "cephfs"
  node_name    = "smith"
  url          = "http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
  file_name    = "debian-12.tar.zst"
}

resource "proxmox_virtual_environment_download_file" "fedora_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "cephfs"
  node_name    = "smith"
  url          = "http://download.proxmox.com/images/system/fedora-41-default_20241118_amd64.tar.xz"
  file_name    = "fedora-41.tar.xz"
}

# =============================================================================
# NixOS Images (built & uploaded via Taskfile, not downloaded)
# =============================================================================
# Build: task nix:build-vm-image && task nix:upload-vm-image
#        task nix:build-lxc-image && task nix:upload-lxc-image

locals {
  nixos_vm_image  = "cephfs:iso/nixos-base-vm.qcow2.img"
  nixos_lxc_image = "cephfs:vztmpl/nixos-base-lxc.tar.xz"
}
