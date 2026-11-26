# IDS Stack VM configuration
# NOTE: Suricata has been moved to run directly on VyOS router
# See: ansible/playbooks/home_router/configure_suricata.yml
#
# Zeek runs as a container capturing traffic from ens19 (mirror bridge)
# Logs are stored in /var/lib/zeek/logs
#
# Secrets Flow:
# - App secrets: SOPS -> Terraform -> OpenBao -> vault-agent -> /run/secrets/
{ config, lib, pkgs, modulesPath, facts, ... }:

{
  imports = [
    ../../../modules/vm-hardware.nix  # Boot/filesystem for nixos-rebuild
    ../../../modules/vm-common.nix    # cloud-init, qemu-guest
    ../../../modules/base.nix         # SSH CA, OTEL, common packages
    ../../../modules/step-ca-cert.nix # Certificate auto-renewal (for machine auth)
    ../../../modules/openbao-agent.nix # Secrets from OpenBao
    ../../../modules/osquery-agent.nix # Fleet-managed osquery endpoint
    ./zeek.nix                         # Zeek network monitor
  ];

  # step-ca certificate auto-renewal (used for machine auth to OpenBao).
  # Deploy this host with `task configure:ids-stack`; its closure is built on
  # nix-builder so Nix evaluation/build I/O cannot starve the live IDS services.
  aether.step-ca-cert = {
    enable = true;
    onRenew = [ "vault-agent.service" ];
  };
  
  # OpenBao agent for secrets management (osquery enroll secret)
  aether.openbao-agent.enable = true;
  aether.osquery-agent.enable = true;

  # Firewall - SSH only (opened by base.nix); the sensors listen on nothing.
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

  # OTEL agent - collect logs (jsonFilelogs defined in zeek.nix)
  aether.otel-agent.filelog.patterns = [
    "/var/log/*.log"
  ];

  # Enable Podman for quadlet containers
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  # Useful tools for IDS analysis
  environment.systemPackages = with pkgs; [
    tcpdump
    tshark
  ];
}
