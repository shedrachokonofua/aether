# step-ca Certificate Renewal Module
#
# Handles automatic certificate renewal for NixOS VMs.
# Assumes certificate is PRE-PROVISIONED via Terraform/cloud-init.
#
# The initial certificate is requested by Terraform during VM creation
# and injected via cloud-init write_files. This module only handles
# automatic renewal using `step ca renew --daemon`.
#
# Certificate paths (populated by cloud-init):
#   - /etc/ssl/certs/machine.crt      - Client certificate (PEM)
#   - /etc/ssl/private/machine.key    - Private key (PEM)  
#   - /etc/ssl/certs/step-ca-root.crt - CA root certificate (PEM)
#
# Usage:
#   aether.step-ca-cert = {
#     enable = true;
#     onRenew = [ "vault-agent.service" ];  # Services to restart after renewal
#   };
{ config, lib, pkgs, facts, ... }:

let
  cfg = config.aether.step-ca-cert;

  certFile = "/etc/ssl/certs/machine.crt";
  keyFile = "/etc/ssl/private/machine.key";
  caCertFile = "/etc/ssl/certs/step-ca-root.crt";
  stepPath = "/etc/step";

  x509ExporterVersion = "4.1.0";
  x509ExporterRelease = {
    "x86_64-linux" = {
      asset = "linux-amd64";
      hash = "sha256-u6+fTYbslmrQMTNXeutaKPHFoLRyCGncSRfSXqo5qZw=";
    };
    "aarch64-linux" = {
      asset = "linux-arm64";
      hash = "sha256-aBLgPdICb47kPGgDrNgwhsCCHx2VBHzyW+VxhZb2zGQ=";
    };
  }.${pkgs.stdenv.hostPlatform.system};

  x509CertificateExporter = pkgs.stdenv.mkDerivation {
    pname = "x509-certificate-exporter";
    version = x509ExporterVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/enix/x509-certificate-exporter/releases/download/v${x509ExporterVersion}/x509-certificate-exporter-v${x509ExporterVersion}-${x509ExporterRelease.asset}.tar.gz";
      hash = x509ExporterRelease.hash;
    };
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
    dontConfigure = true;
    dontBuild = true;
    dontUnpack = true;
    installPhase = ''
      install -d $out/bin
      tar -xzf $src -O x509-certificate-exporter > $out/bin/x509-certificate-exporter
      chmod 0755 $out/bin/x509-certificate-exporter
    '';
  };

  # Build renewal hook command
  renewHookCmd = lib.optionalString (cfg.onRenew != []) 
    (lib.concatMapStringsSep " && " (svc: "${pkgs.systemd}/bin/systemctl restart ${svc}") cfg.onRenew);

in {
  options.aether.step-ca-cert = {
    enable = lib.mkEnableOption "step-ca certificate auto-renewal";
    
    onRenew = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "vault-agent.service" ];
      description = "Systemd services to restart after certificate renewal";
    };
    
    renewBefore = lib.mkOption {
      type = lib.types.str;
      default = "8h";
      description = "Start renewing certificate this long before expiry";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure required directories exist
    systemd.tmpfiles.rules = [
      "d /etc/ssl/certs 0755 root root -"
      "d /etc/ssl/private 0700 root root -"
      "d ${stepPath} 0755 root root -"
    ];

    # Set up step-ca trust from pre-provisioned CA cert (injected via cloud-init)
    # This creates the step config directory structure needed for renewal
    systemd.services.step-ca-bootstrap = {
      description = "Set up step-ca trust from cloud-init cert";
      wantedBy = [ "multi-user.target" ];
      before = [ "step-ca-cert-renew.service" ];
      
      unitConfig = {
        # Only run if not already set up
        ConditionPathExists = "!${stepPath}/certs/root_ca.crt";
      };
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      
      script = ''
        # Create step directories
        mkdir -p ${stepPath}/certs ${stepPath}/config
        
        # Copy CA root cert from cloud-init location
        cp /etc/ssl/certs/step-ca-root.crt ${stepPath}/certs/root_ca.crt
        
        # Create step config
        cat > ${stepPath}/config/defaults.json << EOF
        {
          "ca-url": "${facts.infra.step_ca_internal_url}",
          "root": "${stepPath}/certs/root_ca.crt"
        }
        EOF
      '';
    };

    # Certificate renewal daemon
    # Uses existing certificate to authenticate - NO PASSWORD NEEDED!
    systemd.services.step-ca-cert-renew = {
      description = "step-ca Certificate Auto-Renewal Daemon";
      after = [ "network-online.target" "step-ca-bootstrap.service" ];
      wants = [ "network-online.target" ];
      requires = [ "step-ca-bootstrap.service" ];
      wantedBy = [ "multi-user.target" ];
      
      # Run before services that depend on the certificate
      before = lib.optional (cfg.onRenew != []) (builtins.head cfg.onRenew);
      
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "30";
        Environment = "STEPPATH=${stepPath}";
        
        # step ca renew --daemon:
        # - Watches certificate expiry
        # - Renews automatically before expiry
        # - Uses existing cert to authenticate (no password!)
        # - Runs --exec command after successful renewal
        ExecStart = lib.concatStringsSep " " ([
          "${pkgs.step-cli}/bin/step"
          "ca"
          "renew"
          "--ca-url=${facts.infra.step_ca_internal_url}"
          "--root=${stepPath}/certs/root_ca.crt"
          "--daemon"
          "--expires-in=${cfg.renewBefore}"
        ] ++ lib.optional (renewHookCmd != "") "--exec \"${renewHookCmd}\""
          ++ [ certFile keyFile ]);
      };
    };

    # Export the machine certificate and the renewal daemon through the same
    # local OTEL Prometheus receiver used by the rest of the NixOS host.
    systemd.services.aether-x509-certificate-exporter = {
      description = "Aether X.509 certificate expiry exporter";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "root";
        ExecStart = "${x509CertificateExporter}/bin/x509-certificate-exporter --watch-file=${certFile} --listen-address=127.0.0.1:9793";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };

    services.prometheus.exporters.systemd = {
      enable = true;
      user = "root";
      group = "root";
      listenAddress = "127.0.0.1";
      port = 9558;
      extraFlags = [
        "--systemd.collector.unit-include=^step-ca-cert-renew\\.service$"
      ];
    };

    # The exporter needs access to the system D-Bus unit state. Keep the
    # package's generic DynamicUser default from hiding renewal failures.
    systemd.services.prometheus-systemd-exporter.serviceConfig = {
      DynamicUser = false;
      User = "root";
      Group = "root";
    };

    aether.otel-agent.prometheusScrapeConfigs = lib.mkAfter [
      {
        job_name = "x509-certificate-exporter";
        scrape_interval = "60s";
        targets = [ "127.0.0.1:9793" ];
      }
      {
        job_name = "systemd-exporter";
        scrape_interval = "60s";
        targets = [ "127.0.0.1:9558" ];
      }
    ];

    # Ensure step-cli is available for debugging
    environment.systemPackages = [ pkgs.step-cli ];
  };
}
