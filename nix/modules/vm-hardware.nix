# Hardware config for VMs provisioned from vm-base image
# Only needed for nixos-rebuild (not image building)
# nixos-generators creates: /dev/vda1 (ext4 root), GRUB on /dev/vda
{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
  };
}

