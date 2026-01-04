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
  ];

  # cloud-init for runtime configuration (IP, hostname)
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # QEMU guest agent for Proxmox integration
  services.qemuGuest.enable = true;

  # Enable growpart for automatic partition resize
  boot.growPartition = true;

  # Disk size for the image (nixos-generators proxmox format handles partitioning)
  virtualisation.diskSize = 8192; # 8GB base, Proxmox can resize larger

  # Minimal image - no extra services, OTEL etc added via per-VM config
  # This is intentionally bare - just boot + SSH + cloud-init

  # Hostname placeholder (cloud-init overrides this)
  networking.hostName = lib.mkDefault "nixos";
}

