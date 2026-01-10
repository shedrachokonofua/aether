# OpenBao Agent Module for NixOS
#
# Configures vault-agent to authenticate using step-ca certificates
# and render secrets to /run/secrets/ for consumption by services.
#
# Prerequisites:
#   - Machine certificate must exist at /etc/ssl/certs/machine.crt (pre-provisioned via Terraform/cloud-init)
#   - aether.step-ca-cert should be enabled for auto-renewal
#   - OpenBao must have cert auth backend configured (see tofu/home/openbao_machine_auth.tf)
#   - Secrets must exist at kv/data/aether/<path>
#
# Usage:
#   aether.openbao-agent = {
#     enable = true;
#     templates = {
#       "wazuh.env" = {
#         contents = ''
#           INDEXER_PASSWORD={{ with secret "kv/data/aether/wazuh" }}{{ .Data.data.indexer_password }}{{ end }}
#         '';
#         restartServices = [ "wazuh-indexer.service" ];
#       };
#     };
#   };
{ config, lib, pkgs, facts, ... }:

let
  cfg = config.aether.openbao-agent;
  
  # Build individual template blocks
  templateBlocks = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: tmpl: ''
template {
  destination = "/run/secrets/${name}"
  perms = "${tmpl.perms}"
  contents = <<EOT
${tmpl.contents}
EOT
${lib.optionalString (tmpl.restartServices != []) ''
  exec {
    command = ["${pkgs.systemd}/bin/systemctl", "restart", ${lib.concatMapStringsSep ", " (s: ''"${s}"'') tmpl.restartServices}]
  }
''}
}
  '') cfg.templates);
  
  # Build the agent config file
  agentConfig = pkgs.writeText "vault-agent.hcl" ''
    pid_file = "/run/vault-agent/vault-agent.pid"
    
    vault {
      address = "${cfg.vaultAddr}"
      ca_cert = "${cfg.caCert}"
      client_cert = "${cfg.clientCert}"
      client_key = "${cfg.clientKey}"
    }
    
    auto_auth {
      method "cert" {
        mount_path = "auth/${cfg.authPath}"
        config = {
          name = "${cfg.authRole}"
          client_cert = "${cfg.clientCert}"
          client_key = "${cfg.clientKey}"
        }
      }
      
      sink "file" {
        config = {
          path = "/run/vault-agent/token"
          mode = 0600
        }
      }
    }
    
    ${templateBlocks}
    
    # Keep running and re-render templates when secrets change
    template_config {
      exit_on_retry_failure = true
    }
  '';

in {
  options.aether.openbao-agent = {
    enable = lib.mkEnableOption "OpenBao agent for secrets management";
    
    vaultAddr = lib.mkOption {
      type = lib.types.str;
      default = facts.infra.openbao_internal_url;  # Use internal address for mTLS cert auth
      description = "OpenBao server address";
    };
    
    authPath = lib.mkOption {
      type = lib.types.str;
      default = "cert";
      description = "Path to cert auth backend in OpenBao";
    };
    
    authRole = lib.mkOption {
      type = lib.types.str;
      default = "aether-machine";
      description = "Name of the cert auth role to use";
    };
    
    clientCert = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssl/certs/machine.crt";
      description = "Path to client certificate for cert auth";
    };
    
    clientKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssl/private/machine.key";
      description = "Path to client private key for cert auth";
    };
    
    caCert = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssl/certs/step-ca-root.crt";
      description = "Path to CA certificate for TLS verification";
    };
    
    templates = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          contents = lib.mkOption {
            type = lib.types.lines;
            description = ''
              Template contents using Vault template syntax.
              
              Example:
                INDEXER_PASSWORD={{ with secret "kv/data/nixos/wazuh" }}{{ .Data.data.indexer_password }}{{ end }}
              
              Note: For KV v2, secrets are at .Data.data.<key>
            '';
          };
          perms = lib.mkOption {
            type = lib.types.str;
            default = "0600";
            description = "File permissions for rendered secret";
          };
          restartServices = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Systemd services to restart when secret changes";
            example = [ "wazuh-indexer.service" "wazuh.service" ];
          };
        };
      });
      default = {};
      description = "Secret templates to render to /run/secrets/";
      example = {
        "wazuh.env" = {
          contents = ''
            INDEXER_PASSWORD={{ with secret "kv/data/aether/wazuh" }}{{ .Data.data.indexer_password }}{{ end }}
          '';
          restartServices = [ "wazuh-indexer.service" ];
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Create secrets and agent directories
    systemd.tmpfiles.rules = [
      "d /run/secrets 0700 root root -"
      "d /run/vault-agent 0700 root root -"
    ];
    
    # Vault agent service
    # Cert is pre-provisioned via cloud-init, so we just need network
    systemd.services.vault-agent = {
      description = "OpenBao Agent - Secrets Management";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      
      path = [ pkgs.glibc.getent ];  # getent needed by bao for home dir expansion
      
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.openbao}/bin/bao agent -config=${agentConfig}";
        Restart = "on-failure";
        RestartSec = "5";
        
        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/run/secrets" "/run/vault-agent" ];
        
        # Read access to certificate and key
        ReadOnlyPaths = [ 
          cfg.clientCert 
          cfg.clientKey 
          cfg.caCert
        ];
      };
    };
    
    # Make vault CLI available for debugging
    environment.systemPackages = [ pkgs.openbao ];
    
    # Environment variables for vault CLI (optional, for debugging)
    environment.variables = {
      VAULT_ADDR = cfg.vaultAddr;
      VAULT_CACERT = cfg.caCert;
    };
  };
}
