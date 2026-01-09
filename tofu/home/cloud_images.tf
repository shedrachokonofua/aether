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

# =============================================================================
# Talos Linux Images
# =============================================================================
# Nocloud image from Talos Image Factory with QEMU guest agent extension
# Schematic ID includes: siderolabs/qemu-guest-agent

locals {
  talos_version = "v1.12.1"
  # Schematic with qemu-guest-agent extension
  # Generate at: https://factory.talos.dev/?arch=amd64&extensions=siderolabs%2Fqemu-guest-agent&platform=nocloud
  talos_schematic = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

# Talos ISO for Proxmox boot (nocloud platform)
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "cephfs"
  node_name    = "smith"
  url          = "https://factory.talos.dev/image/${local.talos_schematic}/${local.talos_version}/nocloud-amd64.iso"
  file_name    = "talos-${local.talos_version}-nocloud.iso"
}
