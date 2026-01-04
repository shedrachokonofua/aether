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
            echo "Tools available:"
            echo "  tofu, ansible, sops, age, aws, step, bao"
            echo "  jq, yq, git, task, pre-commit, gitleaks"
            echo ""
          '';
        };

        # Future: NixOS configurations will go here
        # nixosConfigurations = { ... };
      }
    );
}

