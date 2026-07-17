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

  # The OTel collector reads AdGuard's 0600 querylog.json files. Use a fixed
  # service identity so both services can share the query-log group safely.
  users.groups.adguardhome = {};
  users.users.adguardhome = {
    isSystemUser = true;
    group = "adguardhome";
  };

  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    openFirewall = true;

    settings = import ./adguard-settings.nix;
  };

  systemd.services.adguardhome.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "adguardhome";
    Group = "adguardhome";
  };

  systemd.services.opentelemetry-collector.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "adguardhome";
    Group = "adguardhome";
    # The querylog historical replay must never starve DNS: hard-cap the
    # collector so catchup is slow instead of the resolver being unresponsive.
    CPUQuota = "25%";
    MemoryHigh = "256M";
    MemoryMax = "512M";
    IOWeight = 10;
    Nice = 10;
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

  aether.otel-agent.jsonFilelogs.adguard_querylog = {
    # Include the active query log and rotated files for historical replay.
    include = [ "/var/lib/AdGuardHome/data/querylog.json*" ];
    timestampField = "T";
    timestampLayoutType = "gotime";
    timestampLayout = "2006-01-02T15:04:05.999999999Z07:00";
    startAt = "beginning";
    resourceAttributes = {
      "log.source" = "adguard_querylog";
      "dns.log.type" = "query";
    };
  };

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
