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
          "ca-url": "${facts.infra.step_ca_url}",
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
          "--daemon"
          "--expires-in=${cfg.renewBefore}"
        ] ++ lib.optional (renewHookCmd != "") "--exec \"${renewHookCmd}\""
          ++ [ certFile keyFile ]);
      };
    };

    # Ensure step-cli is available for debugging
    environment.systemPackages = [ pkgs.step-cli ];
  };
}
