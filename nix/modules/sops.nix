# Shared sops-nix configuration for all NixOS hosts
{ config, lib, ... }:

{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yml;
    defaultSopsFormat = "yaml";
    
    # Use SSH host key (converted to age automatically)
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}

