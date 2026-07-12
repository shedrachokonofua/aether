{ facts, pkgs, ... }:

{
  imports = [
    ../../modules/vm-hardware.nix
    ../../modules/vm-common.nix
    ../../modules/base.nix
    ../../modules/step-ca-cert.nix
  ];

  networking.hostName = facts.vm.nix_builder.name;

  # Keep build pressure bounded below Neo's Talos/GPU workloads.
  nix = {
    settings = {
      max-jobs = 8;
      cores = 0;
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  systemd.services.nix-daemon.serviceConfig = {
    CPUWeight = 25;
    IOWeight = 25;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/nix-builder 0755 root root -"
  ];

  # The deployment workflow refreshes last-use before and after every build.
  # Preserve the store on disk but release Neo's CPU/RAM after one idle hour.
  systemd.services.nix-builder-idle-shutdown = {
    description = "Power off the Nix builder after one hour idle";
    serviceConfig.Type = "oneshot";
    script = ''
      marker=/var/lib/nix-builder/last-use
      if [ ! -e "$marker" ]; then
        ${pkgs.coreutils}/bin/touch "$marker"
        exit 0
      fi

      if ${pkgs.procps}/bin/pgrep -f 'nix (build|copy)|nix-store --serve|nix-daemon --stdio' >/dev/null; then
        exit 0
      fi

      now=$(${pkgs.coreutils}/bin/date +%s)
      last=$(${pkgs.coreutils}/bin/stat -c %Y "$marker")
      if [ "$((now - last))" -ge 3600 ]; then
        ${pkgs.systemd}/bin/systemctl poweroff
      fi
    '';
  };

  systemd.timers.nix-builder-idle-shutdown = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15m";
      OnUnitActiveSec = "10m";
      Unit = "nix-builder-idle-shutdown.service";
    };
  };

  aether.step-ca-cert.enable = true;
}
