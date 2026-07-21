# Vendored from nixpkgs master (pkgs/by-name/te/technitium-dns-server) and
# bumped to 15.4.0 (needs dotnet SDK/runtime 10; the 25.11 in-tree 15.2 build
# pins SDK 9). Cluster-wide version with rama's container tag. Drop once
# nixpkgs ships >= 15.4.
{
  lib,
  buildDotnetModule,
  fetchFromGitHub,
  dotnetCorePackages,
  technitium-dns-server-library,
  libmsquic,
}:
buildDotnetModule rec {
  pname = "technitium-dns-server";
  version = "15.4.0";

  src = fetchFromGitHub {
    owner = "TechnitiumSoftware";
    repo = "DnsServer";
    tag = "v${version}";
    hash = "sha256-EPqaVulPO5giURtlmj4vMDXYFKICrhJa9TQbQ9AaYJ8=";
  };

  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;

  nugetDeps = ./nuget-deps.json;

  projectFile = [ "DnsServerApp/DnsServerApp.csproj" ];

  # move dependencies from TechnitiumLibrary to the expected directory
  preBuild = ''
    mkdir -p ../TechnitiumLibrary/bin
    cp -r ${technitium-dns-server-library}/lib/${technitium-dns-server-library.pname}/* ../TechnitiumLibrary/bin/
  '';

  postFixup = ''
    mv $out/bin/DnsServerApp $out/bin/technitium-dns-server
  '';

  runtimeDeps = [
    libmsquic
  ];

  meta = {
    changelog = "https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md";
    description = "Authorative and Recursive DNS server for Privacy and Security";
    homepage = "https://github.com/TechnitiumSoftware/DnsServer";
    license = lib.licenses.gpl3Only;
    mainProgram = "technitium-dns-server";
    platforms = lib.platforms.linux;
  };
}
