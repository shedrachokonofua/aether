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
  talos_version      = "v1.12.1"
  talos_rpi_version  = "v1.12.7"
  talos_rpi5_version = "v1.13.2"

  # Standard schematic: qemu-guest-agent + kata-containers + gVisor +
  # binfmt-misc + lldpd + stargz-snapshotter. Sandbox runtimes are for amd64
  # only; Pi nodes excluded due to GICv2 / ARM validation gaps.
  # Generate at: https://factory.talos.dev/?arch=amd64&extensions=siderolabs%2Fbinfmt-misc&extensions=siderolabs%2Fgvisor&extensions=siderolabs%2Fkata-containers&extensions=siderolabs%2Flldpd&extensions=siderolabs%2Fqemu-guest-agent&extensions=siderolabs%2Fstargz-snapshotter&platform=nocloud
  # Previous (qemu-guest-agent only): ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515
  talos_schematic = "b3fca2d1171866364c88096e8243ff8a11eafd1a1af71067ddd8a2abc1ec55d5"

  # Raspberry Pi schematic: no VM-specific extensions. No kata (GICv2).
  talos_rpi_schematic = "ee21ef4a5ef808a9b7484cc0dda0f25075021691c8c09a276591eedb638ea1f9"

  # Raspberry Pi 5 schematic: official sbc-raspberrypi rpi_5 overlay. No kata yet
  # (would work on Pi5 GICv3 in principle, deferred until validated).
  talos_rpi5_schematic = "a636242df247ad4aad2e36d1026d8d4727b716a3061749bd7b19651e548f65e4"

  # GPU schematics — two variants, selected per node via the gpu_input flag so
  # the input extension rolls out one node at a time:
  #   base  = NVIDIA container toolkit LTS + open kernel modules LTS (+ kata,
  #           gvisor, etc). GPU nodes WITHOUT gpu_input use this.
  #   input = base + siderolabs/uinput, for nodes running the Sunshine game-server
  #           (gpu_input: true). uinput provides /dev/uinput for virtual
  #           keyboard/mouse/gamepad injection; Talos omits the input subsystem
  #           from the base image. NOTE: siderolabs/joydev + uhid are NOT yet
  #           published for v1.12.1 (build 400s with them) — uinput alone covers
  #           evdev input; re-add joydev/uhid for legacy /dev/input/js* once they
  #           ship for this Talos version.
  # talos-smith runs the input schematic; talos-neo stays on base until its turn.
  # Previous (no kata): 2e186944edfff6a15572ad75ec2b6f26b35e2542566d640dfcd2ad7c52a2df55
  talos_nvidia_base_schematic = "1fa5d0f0c7a4c18c21248502be69570d133202ad46d644981e8034b63462087d"
  # input = base + siderolabs/uinput. Build-verified 2026-06-27 (installer 200);
  # d952c982… (base + joydev + uhid + uinput) 400s — joydev/uhid unpublished for v1.12.1.
  talos_nvidia_schematic = "88dfed3cc7c944b6c235188339abc08fc0d507b127a45d3c3130f54315b557a4"
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
