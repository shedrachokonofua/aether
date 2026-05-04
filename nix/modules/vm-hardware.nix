# Hardware config for VMs provisioned from vm-base image
# Only needed for nixos-rebuild (not image building)
# vm-base images use GPT with:
#   - /dev/disk/by-label/ESP   mounted at /boot
#   - /dev/disk/by-label/nixos mounted at /
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
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };
}
