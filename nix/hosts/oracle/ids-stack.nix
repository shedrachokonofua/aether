# IDS Stack VM configuration
# NOTE: Suricata has been moved to run directly on VyOS router
# See: ansible/playbooks/home_router/configure_suricata.yml
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ../../modules/vm-hardware.nix  # Boot/filesystem for nixos-rebuild
    ../../modules/vm-common.nix    # cloud-init, qemu-guest
    ../../modules/base.nix         # SSH CA, OTEL, common packages
  ];

  # Firewall - only SSH needed
  networking.firewall.enable = true;
}


