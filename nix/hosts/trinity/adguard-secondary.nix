# Secondary AdGuard Home resolver.
{ lib, ... }:

{
  imports = [
    ../common/technitium-resolver.nix
  ];

  networking.hostName = lib.mkOverride 10 "adguard-secondary";
}
