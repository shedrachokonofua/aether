# Monero daemon (monerod) configuration
# Full node for private cryptocurrency transactions
{ config, lib, pkgs, ... }:

{
  # Monero daemon
  services.monero = {
    enable = true;
    
    # Store blockchain on HDD (NFS mount)
    dataDir = "/var/lib/blockchain/monero";
    
    # Network settings
    mining.enable = false;  # No mining
    
    # RPC for wallet connections (Feather Wallet)
    rpc = {
      address = "0.0.0.0";  # Allow connections from local network
      port = 18081;
      restricted = true;     # Restricted RPC (safe for remote wallets)
    };
    
    extraConfig = ''
      # P2P settings
      p2p-bind-ip=0.0.0.0
      p2p-bind-port=18080
      
      # Confirm external bind for RPC
      confirm-external-bind=1
      
      # Memory settings (tune for shared 8GB VM)
      # db-sync-mode safe uses less RAM but slower
      db-sync-mode=safe
      
      # Connection limits
      out-peers=32
      in-peers=64
      
      # No UPnP (manual port forwarding if needed)
      no-igd=1
      
      # Log level (0=minimal, 1=info, 2=debug)
      log-level=1
    '';
  };

  # Ensure monero user exists
  users.users.monero = {
    isSystemUser = true;
    group = "monero";
    home = "/var/lib/blockchain/monero";
  };
  users.groups.monero = {};

  # Open P2P and RPC ports
  networking.firewall.allowedTCPPorts = [ 18080 18081 ];
}
