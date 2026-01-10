# Zeek Network Security Monitor
# Captures traffic from ens19 (mirror bridge) in promiscuous mode
# Logs stored in /var/lib/zeek/logs as JSON for OTEL ingestion
{ config, lib, pkgs, ... }:

{
  # Zeek JSON logs with proper parsing (extracts fields into LogAttributes)
  aether.otel-agent.jsonFilelogs.zeek = {
    include = [ "/var/lib/zeek/logs/*.log" "/var/lib/zeek/logs/**/*.log" ];
    exclude = [ "/var/lib/zeek/logs/stats.log" ];
    timestampField = "ts";
    resourceAttributes."log.source" = "zeek";
  };
  # Data directories for Zeek
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

  # Zeek container via quadlet
  virtualisation.quadlet.containers.zeek = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/zeek/zeek:latest";
      volumes = [
        "/var/lib/zeek/logs:/logs:Z"
        "/var/lib/zeek/spool:/var/spool/zeek:Z"
      ];
      exec = "zeek -i ens19 local LogAscii::use_json=T Log::default_rotation_interval=1day";
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

  # Cleanup old Zeek logs (OTEL ingests them quickly, 24h retention is plenty)
  systemd.services.zeek-log-cleanup = {
    description = "Clean up old Zeek log files";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.findutils}/bin/find /var/lib/zeek/logs -name '*.log' -mtime +1 -delete";
    };
  };
  systemd.timers.zeek-log-cleanup = {
    description = "Timer for Zeek log cleanup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };
}

