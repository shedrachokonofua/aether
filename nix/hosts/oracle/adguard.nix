# Primary AdGuard Home resolver.
{ lib, ... }:

{
  imports = [
    ../common/adguard-resolver.nix
  ];

  networking.hostName = lib.mkOverride 10 "adguard";
}
