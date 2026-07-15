# Shared AdGuard Home resolver configuration.
{ config, lib, pkgs, modulesPath, ... }:

let
  adguard-exporter = pkgs.buildGoModule rec {
    pname = "adguard-exporter";
    version = "1.2.1";

    src = pkgs.fetchFromGitHub {
      owner = "henrywhitaker3";
      repo = "adguard-exporter";
      rev = "v${version}";
      hash = "sha256-OltYzxBOOcaW3oYNFvxxjG1qRvuLaZfReSeQaNGiRDc=";
    };

    vendorHash = "sha256-fDSR0+INsVBD5XauPdSETMNJZkrIbpKwZ/6Tb2Po4fY=";
  };
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../../modules/base.nix
  ];

  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    openFirewall = true;

    settings = import ./adguard-settings.nix;
  };

  systemd.services.adguard-exporter = {
    description = "AdGuard Home Prometheus Exporter";
    after = [ "network.target" "adguardhome.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      ADGUARD_SERVERS = "http://localhost:3000";
      ADGUARD_USERNAMES = "admin";
      ADGUARD_PASSWORDS = "fakepasswordforexporter";
      INTERVAL = "15s";
    };

    serviceConfig = {
      ExecStart = "${adguard-exporter}/bin/adguard-exporter";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
    };
  };

  aether.otel-agent.prometheusScrapeConfigs = [
    { job_name = "adguard"; targets = [ "localhost:9618" ]; }
  ];

  networking.firewall.allowedTCPPorts = [
    53
    3000
  ];
  networking.firewall.allowedUDPPorts = [
    53
  ];

  services.resolved.enable = false;

  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # Static route to internal network via VyOS router
  systemd.services.add-internal-route = {
    description = "Add route to internal network";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iproute2}/bin/ip route replace 10.0.2.0/24 via 192.168.2.231 dev eth0";
    };
  };
}
