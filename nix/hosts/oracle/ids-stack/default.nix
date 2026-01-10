# IDS Stack VM configuration
# NOTE: Suricata has been moved to run directly on VyOS router
# See: ansible/playbooks/home_router/configure_suricata.yml
#
# Zeek runs as a container capturing traffic from ens19 (mirror bridge)
# Logs are stored in /var/lib/zeek/logs
#
# Wazuh Stack:
# - Manager: Agents connect to port 1514, API on 55000
# - Indexer: OpenSearch for state storage (port 9200)
# - Dashboard: Web UI (port 5601)
# Alerts also sent to Loki via OTEL
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
    ./zeek.nix                         # Zeek network monitor
    ./wazuh.nix                        # Wazuh HIDS stack
  ];

  # step-ca certificate auto-renewal (used for machine auth to OpenBao, not for Wazuh)
  aether.step-ca-cert = {
    enable = true;
    onRenew = [ "vault-agent.service" ];
  };
  
  # OpenBao agent for secrets management (templates defined in wazuh.nix)
  aether.openbao-agent.enable = true;

  # Firewall - SSH + Wazuh stack (ports from config/vm.yml)
  networking.firewall = let
    ports = facts.vm.ids_stack.ports;
  in {
    enable = true;
    allowedTCPPorts = [
      ports.wazuh_agent        # Wazuh agent connections
      ports.wazuh_registration # Wazuh agent registration
      ports.wazuh_api          # Wazuh API
      ports.wazuh_dashboard    # Wazuh Dashboard
    ];
    allowedUDPPorts = [
      ports.wazuh_agent        # Wazuh agent connections (UDP)
    ];
  };

  # Bring up ens19 (mirror interface) without IP - just for promiscuous capture
  networking.interfaces.ens19 = {
    useDHCP = false;
  };
  systemd.network.networks."40-ens19" = {
    matchConfig.Name = "ens19";
    linkConfig.RequiredForOnline = "no";
    networkConfig.LinkLocalAddressing = "no";
  };

  # OTEL agent - collect logs (jsonFilelogs defined in zeek.nix/wazuh.nix)
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

