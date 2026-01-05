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

  # Set hostname from cloud-init user-data after cloud-init runs
  systemd.services.cloud-init-hostname = {
    description = "Set hostname from cloud-init";
    after = [ "cloud-init.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ -f /var/lib/cloud/instance/user-data.txt ]; then
        HOSTNAME=$(${pkgs.yq-go}/bin/yq -r '.hostname // ""' /var/lib/cloud/instance/user-data.txt 2>/dev/null || true)
        if [ -n "$HOSTNAME" ] && [ "$HOSTNAME" != "null" ]; then
          echo "$HOSTNAME" > /proc/sys/kernel/hostname
        fi
      fi
    '';
  };

  # QEMU guest agent for Proxmox integration
  services.qemuGuest.enable = true;

  # Enable growpart for automatic partition resize
  boot.growPartition = true;

  # Disk size for the image (nixos-generators proxmox format handles partitioning)
  virtualisation.diskSize = 8192; # 8GB base, Proxmox can resize larger

  # Minimal image - no extra services, OTEL etc added via per-VM config
  # This is intentionally bare - just boot + SSH + cloud-init

  # Default hostname - cloud-init-hostname service overrides at boot
  networking.hostName = lib.mkDefault "nixos";
}

