# Secondary AdGuard Home resolver.
{ lib, ... }:

{
  imports = [
    ../common/technitium-resolver.nix
  ];

  networking.hostName = lib.mkOverride 10 "adguard-secondary";

  aether.technitium = {
    serverDomain = "ns2.dns.home.shdr.ch";
    vrrpPriority = 150;
    vrrpPeerAddress = "192.168.2.236";
    cluster = {
      mode = "primary";
      domain = "dns.home.shdr.ch";
      nodeIp = "192.168.2.237";
    };
  };
}
