# Base configuration for NixOS LXCs
# Provides: SSH CA trust, OTEL monitoring, common packages
{ config, lib, pkgs, modulesPath, ... }:

let
  cfg = config.aether.lxc;
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ./otel-agent.nix
  ];

  options.aether.lxc = {
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Hostname for the LXC";
    };
  };

  config = {
    # Hostname
    networking.hostName = cfg.hostname;

    # Enable OTEL agent with defaults (can be extended per-host)
    aether.otel-agent = {
      enable = lib.mkDefault true;
      hostname = cfg.hostname;
    };

    # SSH with CA trust + authorized_keys fallback
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        StrictModes = false;
        AuthorizedPrincipalsFile = "/etc/ssh/auth_principals/%u";
      };
      extraConfig = ''
        TrustedUserCAKeys /run/ssh-ca/ca_user_key.pub
      '';
    };

    # Principals - allow 'admin' principal to login as root
    environment.etc."ssh/auth_principals/root".text = "admin\n";

    # Load SSH CA public key from cache (seeded by bootstrap_lxc.yml)
    systemd.services.load-ssh-ca-key = {
      description = "Load SSH CA public key from cache";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /run/ssh-ca
        if [ -f /var/lib/ssh-ca/ca_user_key.pub ]; then
          cp /var/lib/ssh-ca/ca_user_key.pub /run/ssh-ca/ca_user_key.pub
          chmod 644 /run/ssh-ca/ca_user_key.pub
        else
          echo "ERROR: SSH CA key not found in /var/lib/ssh-ca/"
          echo "Run bootstrap_lxc.yml to seed the CA key cache"
          exit 1
        fi
      '';
    };

    # Firewall - SSH always allowed
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };

    # Common packages
    environment.systemPackages = with pkgs; [
      curl
      htop
      vim
      jq
    ];

    # Persistent storage for SSH CA key cache
    systemd.tmpfiles.rules = [
      "d /var/lib/ssh-ca 0755 root root -"
    ];

    # NixOS version
    system.stateVersion = "24.11";
  };
}
