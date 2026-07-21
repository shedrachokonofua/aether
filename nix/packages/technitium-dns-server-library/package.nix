# Vendored from nixpkgs master (pkgs/by-name/te/technitium-dns-server-library)
# and bumped to 15.4.0: the flake's nixos-25.11 only carries 15.2 and the DNS
# HA work standardizes the whole cluster (ns1/ns2/rama) on 15.4. Drop this and
# the sibling technitium-dns-server vendor once nixpkgs ships >= 15.4.
{
  lib,
  buildDotnetModule,
  fetchFromGitHub,
  dotnetCorePackages,
}:
buildDotnetModule rec {
  pname = "technitium-dns-server-library";
  version = "15.4.0";

  src = fetchFromGitHub {
    owner = "TechnitiumSoftware";
    repo = "TechnitiumLibrary";
    tag = "dns-server-v${version}";
    hash = "sha256-h6EXPJTlYatT5IiFrIsZC/LJ5exzAAU8H4DZCimkn7Q=";
  };

  dotnet-sdk = dotnetCorePackages.sdk_10_0;

  nugetDeps = ./nuget-deps.json;

  projectFile = [
    "TechnitiumLibrary.ByteTree/TechnitiumLibrary.ByteTree.csproj"
    "TechnitiumLibrary.Net/TechnitiumLibrary.Net.csproj"
    "TechnitiumLibrary.Security.OTP/TechnitiumLibrary.Security.OTP.csproj"
  ];

  meta = {
    changelog = "https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md";
    description = "Library for Authorative and Recursive DNS server for Privacy and Security";
    homepage = "https://github.com/TechnitiumSoftware/DnsServer";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
