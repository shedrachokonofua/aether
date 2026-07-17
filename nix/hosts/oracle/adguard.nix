# Former AdGuard primary, migrated to Technitium DNS (cluster node ns1).
# Joins the cluster whose primary is ns2 (the trinity LXC); the join
# credential is seeded root-only at /var/lib/technitium-apply/primary.pass
# from sops (secrets.technitium.primary_admin_password).
{ lib, ... }:

{
  imports = [
    ../common/technitium-resolver.nix
  ];

  networking.hostName = lib.mkOverride 10 "adguard";

  aether.technitium = {
    serverDomain = "ns1.dns.home.shdr.ch";
    cluster = {
      mode = "secondary";
      nodeIp = "192.168.2.236";
      primaryUrl = "https://ns2.dns.home.shdr.ch:53443/";
      primaryIp = "192.168.2.237";
    };
  };
}
