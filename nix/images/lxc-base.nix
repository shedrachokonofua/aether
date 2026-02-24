# Base LXC image for Proxmox
# Build with: task nix:build-lxc-image
# This creates a minimal NixOS LXC template with:
# - SSH CA trust (for immediate access after provisioning)
# - Proxmox LXC integration
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../modules/base.nix
  ];

  # Minimal image - no extra services, OTEL etc added via per-host config
  # This is intentionally bare - just boot + SSH

  # Hostname placeholder (set by pct create --hostname)
  networking.hostName = lib.mkDefault "nixos";
}
