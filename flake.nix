{
  description = "Aether - Private cloud infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
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

        # Future: NixOS configurations will go here
        # nixosConfigurations = { ... };
      }
    );
}

