# Fulcrum Electrum Server configuration
# Provides address-indexed queries for Sparrow/Electrum wallets
# 
# NOTE: Fulcrum requires bitcoind to be fully synced before it can complete indexing.
# Initial index build takes 12-24 hours after Bitcoin sync completes.
#
# RPC Password: Read from /run/secrets/bitcoin-rpc-password (rendered by vault-agent)
{ config, lib, pkgs, ... }:

{
  # Fulcrum config template rendered by vault-agent
  aether.openbao-agent.templates."fulcrum.conf" = {
    contents = ''
{{ with secret "kv/data/aether/bitcoind" }}# Bitcoin Core connection
bitcoind = 127.0.0.1:8332
rpcuser = fulcrum
rpcpassword = {{ .Data.data.rpc_password }}

# Data directory (on NVMe for fast queries)
datadir = /data

# Network interfaces
tcp = 0.0.0.0:50001

# Performance tuning for 8GB VM
db_mem = 1024

# Worker threads
worker_threads = 2

# Connection limits
max_clients_per_ip = 12{{ end }}
'';
    perms = "0600";
    restartServices = [ "fulcrum.service" ];
  };

  # Create data directory
  systemd.tmpfiles.rules = [
    "d /var/lib/fulcrum 0755 root root -"
  ];

  # Fulcrum via quadlet (proper systemd integration)
  virtualisation.podman.enable = true;
  
  virtualisation.quadlet.containers.fulcrum = {
    autoStart = true;
    containerConfig = {
      image = "docker.io/cculianu/fulcrum:latest";
      volumes = [
        "/var/lib/fulcrum:/data:Z"
        "/run/secrets/fulcrum.conf:/fulcrum.conf:ro"
      ];
      # Use /usr/bin/Fulcrum to bypass entrypoint's -D injection
      exec = "/usr/bin/Fulcrum /fulcrum.conf";
      podmanArgs = [
        "--network=host"
      ];
    };
    serviceConfig = {
      Restart = "always";
      RestartSec = "10";
    };
    unitConfig = {
      Description = "Fulcrum Electrum Server";
      After = [ "bitcoind-mainnet.service" "vault-agent.service" ];
      Wants = [ "bitcoind-mainnet.service" "vault-agent.service" ];
    };
  };

  # Open Electrum TCP port
  networking.firewall.allowedTCPPorts = [ 50001 ];
}
