# SeaweedFS object store for backup targets.
{ config, lib, pkgs, modulesPath, facts, ... }:

let
  vm = facts.vm.seaweedfs;
  ports = vm.ports;
  weed = "${pkgs.seaweedfs}/bin/weed";
  dataRoot = "/mnt/hdd/seaweedfs";
  activeDataRoot = "${dataRoot}/current";
  masterDir = "/var/lib/seaweedfs/master";
  filerDir = "/var/lib/seaweedfs/filer";
  volumeDir = "${activeDataRoot}/volumes";
  indexDir = "${activeDataRoot}/index";
  secretDir = "${dataRoot}/secrets";
  s3Config = "${secretDir}/s3.json";
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../../../modules/base.nix
  ];

  networking.hostName = lib.mkOverride 10 vm.name;

  users.groups.seaweed = { };
  users.users.seaweed = {
    isSystemUser = true;
    group = "seaweed";
    home = "/var/lib/seaweedfs";
    createHome = true;
  };

  environment.systemPackages = [ pkgs.seaweedfs ];

  networking.firewall.allowedTCPPorts = [
    ports.s3
    ports.filer
    ports.master
    ports.volume
  ];

  environment.etc."seaweedfs/filer.toml".text = ''
    [filer.options]
    recursive_delete = false

    [leveldb2]
    enabled = true
    dir = "${filerDir}/leveldb2"
  '';

  systemd.tmpfiles.rules = [
    "d /etc/seaweedfs 0755 root root -"
    "d /var/lib/seaweedfs 0750 seaweed seaweed -"
    "d ${masterDir} 0750 seaweed seaweed -"
    "d ${filerDir} 0750 seaweed seaweed -"
    "d ${dataRoot} 0755 seaweed seaweed -"
    "d ${activeDataRoot} 0750 seaweed seaweed -"
    "d ${volumeDir} 0750 seaweed seaweed -"
    "d ${indexDir} 0750 seaweed seaweed -"
    "d ${secretDir} 0750 seaweed seaweed -"
  ];

  systemd.services.seaweedfs-master = {
    description = "SeaweedFS Master";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "seaweed";
      Group = "seaweed";
      WorkingDirectory = masterDir;
      ExecStart = ''
        ${weed} master \
          -ip=${vm.ip} \
          -port=${toString ports.master} \
          -mdir=${masterDir} \
          -volumeSizeLimitMB=30000
      '';
      Restart = "always";
      RestartSec = "2s";
    };
  };

  systemd.services.seaweedfs-volume = {
    description = "SeaweedFS Volume";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "seaweedfs-master.service" ];
    wants = [ "network-online.target" "seaweedfs-master.service" ];

    serviceConfig = {
      Type = "simple";
      User = "seaweed";
      Group = "seaweed";
      ExecStartPre = [
        "${pkgs.coreutils}/bin/test -d ${volumeDir}"
        "${pkgs.coreutils}/bin/test -d ${indexDir}"
      ];
      ExecStart = ''
        ${weed} volume \
          -ip=${vm.ip} \
          -port=${toString ports.volume} \
          -mserver=${vm.ip}:${toString ports.master} \
          -dir=${volumeDir} \
          -disk=hdd \
          -dir.idx=${indexDir} \
          -max=0 \
          -minFreeSpace=10
      '';
      Restart = "always";
      RestartSec = "2s";
    };
  };

  systemd.services.seaweedfs-filer = {
    description = "SeaweedFS Filer";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "seaweedfs-master.service" "seaweedfs-volume.service" ];
    wants = [ "network-online.target" "seaweedfs-master.service" "seaweedfs-volume.service" ];

    serviceConfig = {
      Type = "simple";
      User = "seaweed";
      Group = "seaweed";
      WorkingDirectory = filerDir;
      ExecStartPre = "${pkgs.coreutils}/bin/test -d ${filerDir}";
      ExecStart = ''
        ${weed} filer \
          -ip=${vm.ip} \
          -port=${toString ports.filer} \
          -master=${vm.ip}:${toString ports.master} \
          -defaultStoreDir=${filerDir}
      '';
      Restart = "always";
      RestartSec = "2s";
    };
  };

  systemd.services.seaweedfs-s3 = {
    description = "SeaweedFS S3 Gateway";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "seaweedfs-filer.service" ];
    wants = [ "network-online.target" "seaweedfs-filer.service" ];

    serviceConfig = {
      Type = "simple";
      User = "seaweed";
      Group = "seaweed";
      ExecStartPre = "${pkgs.coreutils}/bin/test -f ${s3Config}";
      ExecStart = ''
        ${weed} s3 \
          -ip.bind=${vm.ip} \
          -port=${toString ports.s3} \
          -filer=${vm.ip}:${toString ports.filer} \
          -config=${s3Config}
      '';
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "always";
      RestartSec = "2s";
    };
  };
}
