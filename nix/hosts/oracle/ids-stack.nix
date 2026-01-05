# IDS Stack VM configuration
# NOTE: Suricata has been moved to run directly on VyOS router
# See: ansible/playbooks/home_router/configure_suricata.yml
#
# Zeek runs as a container capturing traffic from ens19 (mirror bridge)
# Logs are stored in /var/lib/zeek/logs
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ../../modules/vm-hardware.nix  # Boot/filesystem for nixos-rebuild
    ../../modules/vm-common.nix    # cloud-init, qemu-guest
    ../../modules/base.nix         # SSH CA, OTEL, common packages
  ];

  # Firewall - only SSH needed
  networking.firewall.enable = true;

  # Bring up ens19 (mirror interface) without IP - just for promiscuous capture
  networking.interfaces.ens19 = {
    useDHCP = false;
  };
  systemd.network.networks."40-ens19" = {
    matchConfig.Name = "ens19";
    linkConfig.RequiredForOnline = "no";
    networkConfig.LinkLocalAddressing = "no";
  };

  # OTEL agent - collect Zeek logs
  aether.otel-agent.filelog.patterns = [
    "/var/log/*.log"
    "/var/lib/zeek/logs/*.log"
    "/var/lib/zeek/logs/**/*.log"
  ];

  # Enable Podman for quadlet containers
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  # Zeek data directory
  systemd.tmpfiles.rules = [
    "d /var/lib/zeek 0755 root root -"
    "d /var/lib/zeek/logs 0755 root root -"
    "d /var/lib/zeek/spool 0755 root root -"
  ];

  # Set ens19 (mirror interface) to promiscuous mode on boot
  systemd.services.zeek-interface-setup = {
    description = "Configure ens19 for Zeek packet capture";
    after = [ "network-online.target" "sys-subsystem-net-devices-ens19.device" ];
    wants = [ "network-online.target" ];
    requires = [ "sys-subsystem-net-devices-ens19.device" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "zeek.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iproute2}/bin/ip link set ens19 up promisc on";
      ExecStop = "${pkgs.iproute2}/bin/ip link set ens19 promisc off";
    };
  };

  # Zeek container via quadlet-nix
  virtualisation.quadlet = {
    containers.zeek = {
      autoStart = true;
      containerConfig = {
        image = "docker.io/zeek/zeek:latest";
        # Mount logs and spool directories
        volumes = [
          "/var/lib/zeek/logs:/logs:Z"
          "/var/lib/zeek/spool:/var/spool/zeek:Z"
        ];
        # Run Zeek on the mirror interface with JSON logging
        exec = "zeek -i ens19 local LogAscii::use_json=T";
        # Host network, capabilities, workdir, and environment via podman args
        podmanArgs = [
          "--network=host"
          "--cap-add=NET_ADMIN"
          "--cap-add=NET_RAW"
          "--workdir=/logs"
          "--env=ZEEK_INTERFACE=ens19"
        ];
      };
      serviceConfig = {
        Restart = "always";
        RestartSec = "10";
      };
      unitConfig = {
        Description = "Zeek Network Security Monitor";
        After = [ "zeek-interface-setup.service" ];
        Requires = [ "zeek-interface-setup.service" ];
      };
    };
  };

  # Useful tools for IDS analysis
  environment.systemPackages = with pkgs; [
    tcpdump
    tshark
  ];
}


