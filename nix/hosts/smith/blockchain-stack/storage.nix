# Storage configuration for blockchain data
# NFS mount from Smith's HDD pool for bulk blockchain storage
{ config, lib, pkgs, facts, ... }:

{
  # NFS client support
  services.rpcbind.enable = true;
  boot.supportedFilesystems = [ "nfs" ];

  # Mount blockchain data from Smith's HDD pool
  # Smith exports /mnt/hdd/blockchain via NFS
  # Use VLAN 2 IP (10.0.2.4) - allowed by SERVICES-to-TRUSTED firewall rule
  fileSystems."/var/lib/blockchain" = {
    device = "${facts.vm.nfs.ip.vyos}:/mnt/hdd/blockchain";
    fsType = "nfs";
    options = [
      "nfsvers=4"
      "rw"
      "hard"
      "intr"
      "noatime"
      "rsize=1048576"
      "wsize=1048576"
      # Don't block boot if NFS unavailable
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };

  # Create directory structure on the NFS mount
  # NixOS bitcoind module creates user per instance: bitcoind-<instance>
  systemd.tmpfiles.rules = [
    "d /var/lib/blockchain 0755 root root -"
    "d /var/lib/blockchain/bitcoin 0750 bitcoind-mainnet bitcoind-mainnet -"
    "d /var/lib/blockchain/monero 0750 monero monero -"
  ];
}
