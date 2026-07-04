# Fleet osquery agent module.
# Canonical flag set mirrors ansible/roles/vm_monitoring_agent/tasks/osquery.yml.
{ config, lib, ... }:

let
  cfg = config.aether.osquery-agent;
in
{
  options.aether.osquery-agent = {
    enable = lib.mkEnableOption "Fleet-managed osquery agent";

    fleetHost = lib.mkOption {
      type = lib.types.str;
      default = "fleet.home.shdr.ch";
      description = "Fleet server hostname used by osquery TLS plugins.";
    };

    enrollSecretPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/osquery-enroll";
      description = "Path to the Fleet enroll secret rendered by OpenBao agent.";
    };

    tlsServerCerts = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssl/certs/ca-certificates.crt";
      description = "CA bundle used by osquery to verify Fleet TLS.";
    };
  };

  config = lib.mkIf cfg.enable {
    aether.openbao-agent.templates."osquery-enroll" = {
      contents = ''{{ with secret "kv/data/aether/fleet" }}{{ .Data.data.enroll_secret }}{{ end }}'';
      noNewline = true;
      perms = "0600";
      restartServices = [ "osqueryd.service" ];
    };

    services.osquery = {
      enable = true;
      flags = {
        tls_hostname = cfg.fleetHost;
        tls_server_certs = cfg.tlsServerCerts;
        enroll_secret_path = cfg.enrollSecretPath;
        enroll_tls_endpoint = "/api/osquery/enroll";
        config_plugin = "tls";
        config_tls_endpoint = "/api/osquery/config";
        config_refresh = "300";
        logger_plugin = "tls";
        logger_tls_endpoint = "/api/osquery/log";
        logger_tls_period = "60";
        distributed_plugin = "tls";
        distributed_tls_read_endpoint = "/api/osquery/distributed/read";
        distributed_tls_write_endpoint = "/api/osquery/distributed/write";
        distributed_interval = "60";
        disable_events = "false";
        enable_file_events = "true";
        host_identifier = "hostname";
      };
    };

    systemd.services.osqueryd = {
      after = [ "vault-agent.service" ];
      wants = [ "vault-agent.service" ];
    };
  };
}
