# Shared config for all VMs (base image + host configs)
# - cloud-init for network/hostname
# - QEMU guest agent
# - Hostname from cloud-init
{ config, lib, pkgs, ... }:

{
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
}

