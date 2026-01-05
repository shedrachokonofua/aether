{
  description = "Aether - Private cloud infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
  };

  outputs = { self, nixpkgs, flake-utils, nixos-generators, disko, quadlet-nix }:
    let
      system = "x86_64-linux";
      
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

      # SSH CA key module - reads from environment variable at build time
      # Build with: SSH_CA_PUBKEY="ecdsa-sha2..." nix build .#vm-base-image --impure
      sshCaModule = { lib, ... }: {
        aether.base.sshCaPubKey = builtins.getEnv "SSH_CA_PUBKEY";
      };

      # System-agnostic outputs (NixOS configurations)
      # Build with: SSH_CA_PUBKEY="$(ssh root@step-ca cat /etc/step-ca/certs/ssh_user_ca_key.pub)" nixos-rebuild ... --impure
      nixosConfigurations = {
        adguard = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = [ otelFixOverlay ]; }
            ./nix/hosts/oracle/adguard.nix
            sshCaModule
          ];
        };
        ids-stack = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = [ otelFixOverlay ]; }
            quadlet-nix.nixosModules.quadlet
            ./nix/hosts/oracle/ids-stack.nix
            sshCaModule
          ];
        };
      };
    in
    # Per-system outputs (dev shells + packages)
    flake-utils.lib.eachDefaultSystem (sys:
      let
        pkgs = nixpkgs.legacyPackages.${sys};
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
    ) // { 
      inherit nixosConfigurations; 
      
      # Base images for VMs and LXCs
      # Build with: SSH_CA_PUBKEY="$(ssh root@step-ca cat /etc/step-ca/certs/ssh_user_ca_key.pub)" nix build .#vm-base-image --impure
      packages.${system} = {
        # qcow2 image for Terraform + cloud-init workflow
        vm-base-image = nixos-generators.nixosGenerate {
          inherit system;
          format = "qcow";
          modules = [
            ./nix/images/vm-base.nix
            sshCaModule
          ];
        };
        
        lxc-base-image = nixos-generators.nixosGenerate {
          inherit system;
          format = "proxmox-lxc";
          modules = [
            ./nix/images/lxc-base.nix
            sshCaModule
          ];
        };
      };
    };
}
