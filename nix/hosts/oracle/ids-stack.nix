# IDS Stack VM configuration
# Suricata container for network intrusion detection
# Captures mirrored traffic from VyOS router on eth1 (span port)
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ../../modules/vm-hardware.nix  # Boot/filesystem for nixos-rebuild
    ../../modules/vm-common.nix    # cloud-init, qemu-guest
    ../../modules/base.nix         # SSH CA, OTEL, common packages
  ];

  # Enable Podman with quadlet support
  virtualisation.quadlet.enable = true;

  # Suricata container - network IDS
  virtualisation.quadlet.containers.suricata = {
    autoStart = true;

    containerConfig = {
      image = "docker.io/jasonish/suricata:latest";

      # Host network mode required for promiscuous capture on eth1
      podmanArgs = [ "--network=host" ];

      # Capabilities required for packet capture
      addCapabilities = [ "NET_ADMIN" "NET_RAW" "SYS_NICE" ];

      # Bind mount for logs (EVE JSON output)
      volumes = [
        "/var/log/suricata:/var/log/suricata:Z"
      ];

      # Capture on ens19 (span port receiving mirrored traffic)
      # Note: Second NIC gets predictable name ens19, not eth1
      exec = "-i ens19";
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Create log directory for Suricata
  systemd.tmpfiles.rules = [
    "d /var/log/suricata 0755 root root -"
  ];

  # Configure OTEL to collect Suricata EVE JSON logs
  aether.otel-agent.filelog.patterns = [
    "/var/log/*.log"
    "/var/log/suricata/eve.json"
  ];

  # Firewall - only SSH needed (Suricata is passive capture)
  # eth1 doesn't need firewall rules - it's promiscuous capture only
  networking.firewall.enable = true;
}


