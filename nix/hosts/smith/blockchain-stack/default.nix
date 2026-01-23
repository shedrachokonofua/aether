# Blockchain Stack VM configuration
# Bitcoin + Monero + Fulcrum + LND for self-sovereign crypto infrastructure
#
# Storage Layout:
#   /                    - Ceph RBD (NVMe) - OS, LND, Fulcrum index
#   /var/lib/blockchain  - NFS from Smith HDD pool - Bitcoin/Monero chains
#
# Deployment:
#   1. Create ZFS dataset on Smith: zfs create -o compression=lz4 hdd/blockchain
#   2. Export via NFS to this VM
#   3. Apply Tofu to provision VM
#   4. Deploy: SSH_CA_PUBKEY="..." nixos-rebuild switch --target-host blockchain-stack --impure
#
# Services start automatically and begin syncing on first boot.
# Full sync takes 3-5 days. Monitor with: journalctl -u bitcoind -f
{ config, lib, pkgs, modulesPath, facts, ... }:

{
  imports = [
    ../../../modules/vm-hardware.nix
    ../../../modules/vm-common.nix
    ../../../modules/base.nix
    ../../../modules/step-ca-cert.nix
    ../../../modules/openbao-agent.nix
    ./storage.nix
    ./bitcoind.nix
    ./monerod.nix
    ./fulcrum.nix
    # ./lnd.nix  # Uncomment after Bitcoin fully synced
  ];

  # step-ca certificate auto-renewal (machine auth to OpenBao)
  aether.step-ca-cert = {
    enable = true;
    onRenew = [ "vault-agent.service" ];
  };

  # OpenBao agent for secrets (RPC passwords, etc.)
  aether.openbao-agent.enable = true;

  # Firewall - blockchain services
  networking.firewall = let
    ports = facts.vm.blockchain_stack.ports;
  in {
    enable = true;
    allowedTCPPorts = [
      # Bitcoin
      ports.bitcoin_p2p     # 8333 - P2P network
      ports.bitcoin_rpc     # 8332 - RPC (internal only, but open for Fulcrum)
      # Monero
      ports.monero_p2p      # 18080 - P2P network
      ports.monero_rpc      # 18081 - RPC (for wallet connections)
      # Electrum (Fulcrum)
      ports.electrum_tcp    # 50001 - TCP connections
      ports.electrum_ssl    # 50002 - SSL connections
      # Lightning (uncomment when LND enabled)
      # ports.lnd_p2p       # 9735 - Lightning P2P
      # ports.lnd_grpc      # 10009 - gRPC API
      # ports.thunderhub    # 3000 - Web UI
    ];
  };

  # OTEL metrics collection
  aether.otel-agent.prometheusScrapeConfigs = [
    # Bitcoin metrics (via bitcoin_exporter or similar)
    # Monero metrics
    # Add exporters as needed
  ];

  # Useful tools for blockchain operations
  environment.systemPackages = with pkgs; [
    bitcoin       # bitcoin-cli
    monero-cli    # monero-wallet-cli
  ];
}

