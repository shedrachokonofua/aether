# Shared facts for all NixOS hosts
# Reads configuration files and makes them available as Nix attributes
#
# Usage in flake.nix:
#   specialArgs = { inherit (import ./nix/lib/facts.nix { inherit pkgs; }) facts; };
#
# Usage in modules:
#   { facts, ... }: { networking.hostName = facts.vm.ids_stack.name; }
{ pkgs }:

let
  vmConfigFile = ../../config/vm.yml;
  authorizedKeysFile = ../../config/authorized_keys;
  aetherRootString = builtins.toString ../..;
  
  # Convert YAML to JSON using yq (IFD - import from derivation)
  vmConfigJson = pkgs.runCommandLocal "vm-config-json" {
    nativeBuildInputs = [ pkgs.yq-go ];
  } ''
    yq -o=json ${vmConfigFile} > $out
  '';
  
  # Parse authorized_keys file, filtering comments and empty lines
  parseAuthorizedKeys = content:
    builtins.filter (line: line != "" && !(builtins.match "^#.*" line != null))
      (builtins.split "\n" content);

  # Parse VM config once for reuse
  vm = builtins.fromJSON (builtins.readFile vmConfigJson);

in {
  facts = {
    # VM configuration from config/vm.yml
    inherit vm;
    
    # Terraform outputs (already JSON)
    tf_outputs = 
      let path = "${aetherRootString}/secrets/tf-outputs.json";
      in if builtins.pathExists path
         then builtins.fromJSON (builtins.readFile path)
         else {};
    
    # SSH authorized keys (parsed from config/authorized_keys)
    ssh_authorized_keys = parseAuthorizedKeys (builtins.readFile authorizedKeysFile);
    
    # Infrastructure constants
    infra = {
      step_ca_url = "https://ca.shdr.ch";
      step_ca_internal_url = "https://${vm.step_ca.ip}:${toString vm.step_ca.ports.https}";
      openbao_url = "https://bao.home.shdr.ch";
      openbao_internal_url = "https://${vm.openbao.ip}:${toString vm.openbao.ports.https}";
      keycloak_url = "https://auth.shdr.ch";
      keycloak_realm = "aether";
    };
  };
}
