# Bitcoin Core (bitcoind) configuration
# Full node for transaction verification and Fulcrum/LND backend
#
# RPC Authentication:
#   Credentials stored in OpenBao at kv/data/aether/bitcoind
#   Rendered to /run/secrets/bitcoin-rpc.conf by vault-agent
#   Generate with: nix-shell -p bitcoind --run "bitcoin-rpcauth fulcrum"
{ config, lib, pkgs, ... }:

{
  # OpenBao templates for Bitcoin RPC credentials
  # Note: NixOS bitcoind module creates user per instance: bitcoind-<instance>
  aether.openbao-agent.templates = {
    # RPC auth config for bitcoind (included via includeconf)
    "bitcoin-rpc.conf" = {
      contents = ''{{ with secret "kv/data/aether/bitcoind" }}rpcauth={{ .Data.data.rpc_auth }}{{ end }}'';
      perms = "0600";
      user = "bitcoind-mainnet";
      group = "bitcoind-mainnet";
      restartServices = [ "bitcoind-mainnet.service" ];
    };
    # Plain password for Fulcrum/LND to connect
    "bitcoin-rpc-password" = {
      contents = ''{{ with secret "kv/data/aether/bitcoind" }}{{ .Data.data.rpc_password }}{{ end }}'';
      perms = "0640";
      user = "root";
      group = "bitcoind-mainnet";  # Allows bitcoind and containers to read
      noNewline = true;  # Auth passwords must not have trailing newline
    };
  };

  # Bitcoin daemon
  services.bitcoind."mainnet" = {
    enable = true;
    
    # Store blockchain on HDD (NFS mount)
    dataDir = "/var/lib/blockchain/bitcoin";
    
    # Network settings
    port = 8333;          # P2P port
    rpc.port = 8332;      # RPC port
    
    extraConfig = ''
      # Include RPC auth from OpenBao (rendered by vault-agent)
      includeconf=/run/secrets/bitcoin-rpc.conf
      
      # Full transaction index (required for Fulcrum)
      txindex=1
      
      # Memory settings (tune for 8GB total VM RAM)
      # Lower dbcache = slower sync but less RAM
      dbcache=1000
      
      # Limit connections to save resources
      maxconnections=40
      
      # Parallel script verification threads
      par=2
      
      # Prune is disabled (full node for Fulcrum)
      prune=0
      
      # RPC settings
      server=1
      rpcbind=127.0.0.1
      rpcallowip=127.0.0.1
      
      # ZMQ for LND (when enabled)
      zmqpubrawblock=tcp://127.0.0.1:28332
      zmqpubrawtx=tcp://127.0.0.1:28333
    '';
  };

  # Ensure bitcoind waits for secrets from vault-agent
  systemd.services.bitcoind-mainnet = {
    after = [ "vault-agent.service" ];
    wants = [ "vault-agent.service" ];
  };

  # Ensure bitcoin user exists and has correct permissions
  users.users.bitcoin = {
    isSystemUser = true;
    group = "bitcoin";
    home = "/var/lib/blockchain/bitcoin";
  };
  users.groups.bitcoin = {};
}
