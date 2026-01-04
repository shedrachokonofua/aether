{
  description = "Aether - Private cloud infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Overlay to fix opentelemetry-collector-contrib in >= 24.11
      # See: https://github.com/NixOS/nixpkgs/issues/368321
      otelFixOverlay = final: prev: {
        opentelemetry-collector-contrib =
          let
            pkg = prev.opentelemetry-collector-contrib;
          in
          if final.lib.versionOlder pkg.version "0.112" || final.lib.versionAtLeast pkg.version "0.114"
          then pkg
          else
            let
              commit = "17ddfd8ca1090321149a6d857110fd8eee856569";
              opentelemetry-collector-builder = final.callPackage
                (final.fetchurl {
                  url = "https://github.com/NixOS/nixpkgs/raw/${commit}/pkgs/tools/misc/opentelemetry-collector/builder.nix";
                  hash = "sha256-A46CZH8wQLDix3nYTWPx8ZJJoKbu0Nu36eTW5361TvU=";
                })
                { };
              opentelemetry-collector-releases = final.callPackage
                (final.fetchurl {
                  url = "https://github.com/NixOS/nixpkgs/raw/${commit}/pkgs/tools/misc/opentelemetry-collector/releases.nix";
                  hash = "sha256-JBWakNxHDPI3vSdhBoZ+WQn5adahV1iigOOTm0fjrkQ=";
                })
                { inherit opentelemetry-collector-builder; };
            in
            opentelemetry-collector-releases.otelcol-contrib;
      };

      # System-agnostic outputs (NixOS configurations)
      nixosConfigurations = {
        adguard = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = [ otelFixOverlay ]; }
            ./nix/hosts/oracle/adguard.nix
          ];
        };
      };
    in
    # Per-system outputs (dev shells)
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # Dev shell - replaces Docker toolbox
        devShells.default = pkgs.mkShell {
          name = "aether";
          
          packages = with pkgs; [
            # Infrastructure as Code
            opentofu
            ansible
            python3Packages.ansible-pylibssh  # For network_cli connections (VyOS)
            
            # Secrets management
            sops
            age
            
            # Cloud CLIs
            awscli2
            
            # Certificate management
            step-cli
            
            # Utilities
            jq
            yq-go
            curl
            unzip
            openssh
            git
            
            # Code quality
            pre-commit
            gitleaks
            
            # Task runner
            go-task
            
            # OpenBao CLI (Vault fork)
            openbao
          ];

          shellHook = ''
            echo "🚀 Aether dev shell loaded"
            echo ""
          '';
        };
      }
    ) // { inherit nixosConfigurations; };
}
