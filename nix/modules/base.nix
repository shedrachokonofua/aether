# Base configuration shared by all NixOS VMs and LXCs
# Provides: SSH CA trust, common packages, firewall basics, monitoring
{ config, lib, pkgs, ... }:

let
  cfg = config.aether.base;
in
{
  imports = [
    ./otel-agent.nix
  ];

  options.aether = {
    base = {
      sshCaPubKey = lib.mkOption {
        type = lib.types.str;
        description = "SSH user CA public key from step-ca";
        example = "ecdsa-sha2-nistp256 AAAA...";
      };

      additionalPrincipals = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional principals allowed to SSH as root (admin is always included)";
      };
    };
  };

  config = {
    # Set hostname immediately on activation (VMs only - LXCs can't write to /proc/sys/kernel/hostname)
    # Reads from cloud-init user-data if networking.hostName is default "nixos"
    system.activationScripts.hostname = lib.mkIf config.services.cloud-init.enable {
      deps = [];
      text = ''
        HOSTNAME="${config.networking.hostName}"
        if [ "$HOSTNAME" = "nixos" ] && [ -f /var/lib/cloud/instance/user-data.txt ]; then
          CLOUD_HOSTNAME=$(${pkgs.yq-go}/bin/yq -r '.hostname // ""' /var/lib/cloud/instance/user-data.txt 2>/dev/null || true)
          if [ -n "$CLOUD_HOSTNAME" ] && [ "$CLOUD_HOSTNAME" != "null" ]; then
            HOSTNAME="$CLOUD_HOSTNAME"
          fi
        fi
        echo "$HOSTNAME" > /proc/sys/kernel/hostname
      '';
    };

    # Enable monitoring by default on all machines
    # OTEL uses resourcedetection to auto-detect hostname from OS
    aether.otel-agent.enable = lib.mkDefault true;

    # aether user - standard admin user for all VMs/LXCs
    users.users.aether = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      # No password - SSH CA is the auth method
    };

    # Passwordless sudo for wheel group
    security.sudo.wheelNeedsPassword = false;

    # SSH with CA trust
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        # StrictModes must be disabled for NixOS because principals/CA files
        # are symlinks into /nix/store which has permissions sshd doesn't like
        StrictModes = false;
        AuthorizedPrincipalsFile = "/etc/ssh/auth_principals/%u";
      };
      extraConfig = ''
        TrustedUserCAKeys /etc/ssh/ca_user_key.pub
      '';
    };

    # Embed SSH CA public key directly (ensure trailing newline)
    environment.etc."ssh/ca_user_key.pub".text = cfg.sshCaPubKey + "\n";

    # Principals - allow 'admin' principal to login as root and aether
    environment.etc."ssh/auth_principals/root".text = 
      lib.concatStringsSep "\n" ([ "admin" ] ++ cfg.additionalPrincipals) + "\n";
    environment.etc."ssh/auth_principals/aether".text = 
      lib.concatStringsSep "\n" ([ "admin" ] ++ cfg.additionalPrincipals) + "\n";

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

    # Trust root and aether for nix store operations (needed for nixos-rebuild --target-host)
    nix.settings.trusted-users = [ "root" "aether" ];

    # NixOS version
    system.stateVersion = lib.mkDefault "24.11";
  };
}

