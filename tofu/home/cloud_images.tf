# =============================================================================
# Downloaded Images (managed by Terraform)
# =============================================================================

resource "proxmox_virtual_environment_download_file" "oracle_fedora_image" {
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = "oracle"
  url                 = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name           = "fedora-41.qcow2.img"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_download_file" "niobe_fedora_image" {
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = "niobe"
  url                 = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name           = "fedora-41.qcow2.img"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_download_file" "neo_fedora_image" {
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = "neo"
  url                 = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name           = "fedora-41.qcow2.img"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_download_file" "fedora_image" {
  content_type        = "iso"
  datastore_id        = "cephfs"
  node_name           = "smith"
  url                 = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name           = "fedora-41.qcow2.img"
  overwrite_unmanaged = true
}

# Commented out - file already exists, URL is stale (404)
# resource "proxmox_virtual_environment_download_file" "debian_lxc_template" {
#   content_type = "vztmpl"
#   datastore_id = "cephfs"
#   node_name    = "smith"
#   url          = "http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
#   file_name    = "debian-12.tar.zst"
# }

resource "proxmox_virtual_environment_download_file" "fedora_lxc_template" {
  content_type        = "vztmpl"
  datastore_id        = "cephfs"
  node_name           = "smith"
  url                 = "http://download.proxmox.com/images/system/fedora-41-default_20241118_amd64.tar.xz"
  file_name           = "fedora-41.tar.xz"
  overwrite_unmanaged = true
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

  # Standard schematic: qemu-guest-agent
  # Generate at: https://factory.talos.dev/?arch=amd64&extensions=siderolabs%2Fqemu-guest-agent&platform=nocloud
  talos_schematic = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"

  # Raspberry Pi schematic: no VM-specific extensions.
  talos_rpi_schematic = "ee21ef4a5ef808a9b7484cc0dda0f25075021691c8c09a276591eedb638ea1f9"

  # Raspberry Pi 5 schematic: official sbc-raspberrypi rpi_5 overlay.
  talos_rpi5_schematic = "a636242df247ad4aad2e36d1026d8d4727b716a3061749bd7b19651e548f65e4"

  # GPU schematic: qemu-guest-agent + NVIDIA open kernel modules LTS + NVIDIA container toolkit LTS.
  # Generate at: https://factory.talos.dev/?arch=amd64&extensions=siderolabs%2Fqemu-guest-agent&extensions=siderolabs%2Fnvidia-open-gpu-kernel-modules-lts&extensions=siderolabs%2Fnvidia-container-toolkit-lts&platform=nocloud
  talos_nvidia_schematic = "2e186944edfff6a15572ad75ec2b6f26b35e2542566d640dfcd2ad7c52a2df55"
}

# Talos ISO for Proxmox boot (nocloud platform)
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type        = "iso"
  datastore_id        = "cephfs"
  node_name           = "smith"
  url                 = "https://factory.talos.dev/image/${local.talos_schematic}/${local.talos_version}/nocloud-amd64.iso"
  file_name           = "talos-${local.talos_version}-nocloud.iso"
  overwrite_unmanaged = true
}

# Talos ISO with NVIDIA extensions for GPU node (talos-neo)
resource "proxmox_virtual_environment_download_file" "talos_nvidia_iso" {
  content_type        = "iso"
  datastore_id        = "cephfs"
  node_name           = "smith"
  url                 = "https://factory.talos.dev/image/${local.talos_nvidia_schematic}/${local.talos_version}/nocloud-amd64.iso"
  file_name           = "talos-${local.talos_version}-nvidia-nocloud.iso"
  overwrite_unmanaged = true
}
