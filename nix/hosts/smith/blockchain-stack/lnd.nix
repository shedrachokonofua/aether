# LND (Lightning Network Daemon) + ThunderHub configuration
# Layer 2 Bitcoin payments - instant, cheap transactions
#
# IMPORTANT: Only enable after bitcoind is FULLY SYNCED.
# LND requires current chain state to safely manage channels.
#
# To enable:
#   1. Wait for bitcoind sync: bitcoin-cli getblockchaininfo | jq .verificationprogress
#   2. Uncomment ./lnd.nix import in default.nix
#   3. nixos-rebuild switch
#
# Secrets from OpenBao:
#   - Bitcoin RPC password: kv/data/aether/bitcoind
#   - ThunderHub password: kv/data/aether/lnd
{ config, lib, pkgs, ... }:

{
  # OpenBao templates for LND secrets
  aether.openbao-agent.templates = {
    # LND config with bitcoind password (only the password part, rest via NixOS module)
    "lnd-bitcoind.conf" = {
      contents = ''{{ with secret "kv/data/aether/bitcoind" }}bitcoind.rpcpass={{ .Data.data.rpc_password }}{{ end }}'';
      perms = "0600";
      restartServices = [ "lnd.service" ];
    };
    # ThunderHub config with master password
    "thunderhub-accounts.yaml" = {
      contents = ''
{{ with secret "kv/data/aether/lnd" }}masterPassword: '{{ .Data.data.thunderhub_password }}'
accounts:
  - name: 'main'
    serverUrl: '127.0.0.1:10009'
    macaroonPath: '/var/lib/lnd/data/chain/bitcoin/mainnet/admin.macaroon'
    certificatePath: '/var/lib/lnd/tls.cert'{{ end }}
'';
      perms = "0600";
      restartServices = [ "podman-thunderhub.service" ];
    };
  };

  # LND Lightning daemon
  services.lnd = {
    enable = true;
    
    # Data on NVMe (channel state needs fast, reliable writes)
    dataDir = "/var/lib/lnd";
    
    # Bitcoin backend
    bitcoind = {
      host = "127.0.0.1";
      rpcuser = "fulcrum";  # Reuse the RPC user
      # rpcpassword rendered to /run/secrets/lnd-bitcoind.conf
    };
    
    extraConfig = ''
      # Include bitcoind password from OpenBao
      include=/run/secrets/lnd-bitcoind.conf
      
      # Network
      bitcoin.active=1
      bitcoin.mainnet=1
      bitcoin.node=bitcoind
      
      # Bitcoind connection
      bitcoind.rpchost=127.0.0.1:8332
      bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
      bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333
      
      # Listen for P2P connections
      listen=0.0.0.0:9735
      
      # RPC/REST
      rpclisten=0.0.0.0:10009
      restlisten=0.0.0.0:8080
      
      # Alias (visible to other nodes)
      alias=sovereign-node
      
      # Autopilot disabled (manual channel management)
      autopilot.active=0
      
      # Watchtower client (optional, for channel protection)
      # wtclient.active=1
    '';
  };

  # LND depends on vault-agent for secrets
  systemd.services.lnd = {
    after = [ "vault-agent.service" "bitcoind-mainnet.service" ];
    wants = [ "vault-agent.service" ];
  };

  # ThunderHub web UI for Lightning management
  virtualisation.oci-containers.containers.thunderhub = {
    image = "apotdevin/thunderhub:latest";
    autoStart = true;
    
    ports = [ "3000:3000" ];
    
    # Config rendered by vault-agent
    volumes = [
      "/run/secrets/thunderhub-accounts.yaml:/cfg/accounts.yaml:ro"
      "/var/lib/lnd:/var/lib/lnd:ro"
    ];
    
    environment = {
      ACCOUNT_CONFIG_PATH = "/cfg/accounts.yaml";
      LOG_LEVEL = "info";
    };
    
    dependsOn = [ ];
  };

  # ThunderHub depends on LND and secrets
  systemd.services.podman-thunderhub = {
    after = [ "lnd.service" "vault-agent.service" ];
    wants = [ "lnd.service" "vault-agent.service" ];
  };

  # Open Lightning ports (uncomment in default.nix firewall too)
  networking.firewall.allowedTCPPorts = [
    9735   # LND P2P
    10009  # LND gRPC
    3000   # ThunderHub
  ];
}
