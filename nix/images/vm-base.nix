# Base VM image for Proxmox
# Build with: task nix:build-vm-image
# This creates a minimal bootable NixOS image with:
# - SSH CA trust (for immediate access after provisioning)
# - cloud-init (for network/hostname configuration)
# - QEMU guest agent
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ../modules/base.nix
    ../modules/vm-common.nix
  ];

  # Disk size for the image (nixos-generators handles partitioning/bootloader)
  virtualisation.diskSize = 8192; # 8GB base, Proxmox can resize larger

  # Default hostname - cloud-init-hostname service overrides at boot
  networking.hostName = lib.mkDefault "nixos";
}

