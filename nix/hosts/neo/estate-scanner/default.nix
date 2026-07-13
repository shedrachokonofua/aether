# Estate scanner LXC — active discovery / fingerprint / Nuclei validation
# data plane on INFRA (VLAN 2, 10.0.2.13). See docs/exploration/estate-scanning.md.
#
# Unprivileged LXC. CAP_NET_RAW proven via nmap/naabu SYN. Do not privilege the
# container; fall back to a VM only if raw sockets regress.
{ config, lib, pkgs, modulesPath, facts, ... }:

let
  vm = facts.vm.estate_scanner;
  stateDir = "/var/lib/estate-scanner";
  profilesDir = "${stateDir}/profiles";
  runsDir = "${stateDir}/runs";
  artifactsDir = "${stateDir}/artifacts";
  templatesDir = "${stateDir}/nuclei-templates";
  lockFile = "${stateDir}/scan.lock";

  approvedProfiles = [
    "discovery-common"
    "critical-full-tcp"
    "known-hosts-full-tcp"
    "estate-blind-full-tcp"
    "udp-common"
    "nuclei-daily"
    "nuclei-weekly"
    "cloud-public"
    "cloud-private"
  ];

  approvedTargetGroups = [
    "home"
    "iot"
    "gigahub"
    "calib-server"
    "cidr-infra"
    "aws-public"
    "aws-private"
    "gcp-public"
    "gcp-private"
  ];

  # Profile → Naabu port/rate policy (Phase 3 calibration + production cadences).
  discoverProfiles = {
    discovery-common = {
      ports = "top-100";
      rate = 100;
      concurrency = 10;
      timeout = 3;
      retries = 1;
    };
    critical-full-tcp = {
      ports = "all";
      # Calibration evidence: filtered ports + timeout=5 at 25pps never finishes.
      # Servers stay above IoT/Gigahub; raise only after measured IDS/VyOS headroom.
      rate = 100;
      concurrency = 25;
      timeout = 2;
      retries = 1;
    };
    known-hosts-full-tcp = {
      ports = "all";
      rate = 100;
      concurrency = 25;
      timeout = 2;
      retries = 1;
    };
    estate-blind-full-tcp = {
      ports = "top-1000";
      rate = 50;
      concurrency = 10;
      timeout = 3;
      retries = 1;
    };
  };

  # Per-group UPPER bounds for fragile classes only (IoT / Gigahub).
  # Do not put server/CIDR groups here — that caps full-TCP below the profile rate.
  discoverGroupRates = {
    iot = 5;
    gigahub = 5;
  };

  # CIDR expansions for blind/common-port sweeps (not declared host lists).
  discoverCidrs = {
    cidr-infra = [ "10.0.2.0/24" ];
  };

  approvedStages = [
    "targets"
    "discover"
    "merge-diff"
    "fingerprint"
    "validate"
    "finalize"
    "status"
  ];

  nucleiTemplatesRevision = "v10.4.5";
  nucleiTemplates = pkgs.fetchFromGitHub {
    owner = "projectdiscovery";
    repo = "nuclei-templates";
    rev = nucleiTemplatesRevision;
    hash = "sha256-6czf84bHyvHIT9rA2HUYqQe7lgODl4uRMP/8QepV3AU=";
  };

  # Classify declared addresses into scan target groups by prefix / name.
  groupFor = name: ip:
    let
      byPrefix =
        if lib.hasPrefix "10.1." ip then [ "aws-private" ]
        else if lib.hasPrefix "10.2." ip && !lib.hasPrefix "10.0.2." ip then [ "gcp-private" ]
        else if lib.hasPrefix "192.168.2." ip then [ "gigahub" "home" ]
        else if lib.hasPrefix "10.0.6." ip then [ "iot" "home" ]
        else if lib.hasPrefix "10.0." ip then [ "home" ]
        else [ "home" ];
      extras =
        (lib.optional (name == "monitoring-stack") "calib-server")
        ++ (lib.optional (name == "iot-management-stack") "iot")
        ++ (lib.optional (name == "gigahub-gateway") "gigahub");
    in
    lib.unique (byPrefix ++ extras);

  mkTarget = name: address: {
    inherit name address;
    provenance = "declared";
    owning_source_file = "config/vm.yml";
    target_groups = groupFor name address;
  };

  # Declared estate IPs from authoritative inventory (no cloud API resolution yet).
  declaredTargetList = lib.filter (t: t.address != null && t.address != "") [
    (mkTarget "home-gateway-stack" facts.vm.home_gateway_stack.ip)
    (mkTarget "monitoring-stack" facts.vm.monitoring_stack.ip)
    (mkTarget "nfs" facts.vm.nfs.ip.vyos)
    (mkTarget "gitlab" facts.vm.gitlab.ip)
    (mkTarget "cockpit" facts.vm.cockpit.ip)
    (mkTarget "notifications-stack" facts.vm.notifications_stack.ip)
    (mkTarget "seaweedfs" facts.vm.seaweedfs.ip)
    (mkTarget "keycloak" facts.vm.keycloak.ip)
    (mkTarget "openbao" facts.vm.openbao.ip)
    (mkTarget "bastion" facts.vm.bastion.ip)
    (mkTarget "intrusion-detection-stack" facts.vm.ids_stack.ip)
    (mkTarget "nix-builder" facts.vm.nix_builder.ip)
    (mkTarget "estate-scanner" facts.vm.estate_scanner.ip)
    (mkTarget "iot-management-stack" facts.vm.iot_management_stack.ip)
    (mkTarget "blockchain-stack" facts.vm.blockchain_stack.ip)
    (mkTarget "talos-trinity" facts.vm.talos_trinity.ip)
    (mkTarget "talos-neo" facts.vm.talos_neo.ip)
    (mkTarget "talos-niobe" facts.vm.talos_niobe.ip)
    (mkTarget "talos-smith" facts.vm.talos_smith.ip)
    (mkTarget "adguard" facts.vm.adguard.ip)
    (mkTarget "adguard-secondary" facts.vm.adguard_secondary.ip)
    (mkTarget "step-ca" facts.vm.step_ca.ip)
    (mkTarget "backup-stack" facts.vm.backup_stack.ip)
    # ISP Gigahub CPE (lowest-rate calibration / discovery).
    (mkTarget "gigahub-gateway" facts.vm.router.gateway.gigahub)
  ];

  declaredTargetsJson = pkgs.writeText "declared-targets.json" (builtins.toJSON {
    generated_from = "config/vm.yml";
    targets = declaredTargetList;
  });

  naabuWrapped = pkgs.symlinkJoin {
    name = "naabu-estate";
    paths = [ pkgs.naabu ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/naabu \
        --add-flags "-no-stdin" \
        --add-flags "-duc"
    '';
  };

  # Nuclei 3.x defaults auth/PDCP on and embeds Google IPv6 DNS
  # (2001:4860:4860::8888). Without a shim + auth:false it either prompts on
  # /dev/tty or spins for minutes on ENETUNREACH. HOME points at a clean
  # config that disables PDCP; the dns-shim unit answers the hardcoded resolvers.
  nucleiWrapped = pkgs.symlinkJoin {
    name = "nuclei-estate";
    paths = [ pkgs.nuclei ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/nuclei \
        --set HOME ${stateDir}/nuclei-home \
        --add-flags "-duc" \
        --add-flags "-disable-update-check"
    '';
  };

  nucleiDnsShim = pkgs.writers.writeBabashkaBin "estate-nuclei-dns-shim" {
    check = "";
  } (builtins.readFile ./nuclei-dns-shim.bb);

  httpxWrapped = pkgs.symlinkJoin {
    name = "httpx-estate";
    paths = [ pkgs.httpx ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/httpx \
        --add-flags "-no-stdin" \
        --add-flags "-duc"
    '';
  };

  runtimeConfigJson = pkgs.writeText "estate-scanner-runtime.json" (builtins.toJSON {
    state_dir = stateDir;
    runs_dir = runsDir;
    artifacts_dir = artifactsDir;
    templates_dir = templatesDir;
    lock_file = lockFile;
    declared_targets = "/etc/estate-scanner/declared-targets.json";
    naabu = "${naabuWrapped}/bin/naabu";
    httpx = "${httpxWrapped}/bin/httpx";
    nuclei = "${nucleiWrapped}/bin/nuclei";
    scanner_revision = "estate-scanner-nixos";
    nuclei_templates_revision = nucleiTemplatesRevision;
    approved_profiles = approvedProfiles;
    approved_target_groups = approvedTargetGroups;
    approved_stages = approvedStages;
    discover_profiles = discoverProfiles;
    discover_group_rates = discoverGroupRates;
    discover_cidrs = discoverCidrs;
    # Password is Ansible/SOPS-managed — never bake it into the Nix closure.
    clickhouse_url = "http://${facts.vm.monitoring_stack.ip}:${toString facts.vm.monitoring_stack.ports.clickhouse}";
    clickhouse_user = "estate_scan";
    clickhouse_password_file = "/etc/estate-scanner/clickhouse-password";
  });

  aetherScan = pkgs.writers.writeBabashkaBin "aether-scan" {
    # Skip clj-kondo in the guest build; lint locally / in CI if desired.
    check = "";
  } (builtins.readFile ./aether-scan.bb);
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../../../modules/base.nix
  ];

  networking.hostName = lib.mkOverride 10 vm.name;

  networking.nameservers = [
    vm.gateway
    facts.vm.adguard.ip
    facts.vm.adguard_secondary.ip
  ];

  # Keep IPv6 on lo only so we can bind Nuclei's hardcoded Google DNS addrs.
  networking.enableIPv6 = true;
  networking.interfaces.lo.ipv6.addresses = [
    {
      address = "2001:4860:4860::8888";
      prefixLength = 128;
    }
    {
      address = "2001:4860:4860::8844";
      prefixLength = 128;
    }
  ];

  # Do not fall back to public IPv6 resolvers via systemd-resolved.
  services.resolved.fallbackDns = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  environment.systemPackages = [
    aetherScan
    naabuWrapped
    httpxWrapped
    nucleiWrapped
    nucleiDnsShim
    pkgs.nmap
    pkgs.babashka
    pkgs.util-linux # setsid for detached discover workers
    pkgs.jq
    pkgs.yq-go
  ];

  systemd.services.estate-nuclei-dns-shim = {
    description = "Forward Nuclei hardcoded Google IPv6 DNS to lab resolver";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "systemd-networkd-wait-online.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${nucleiDnsShim}/bin/estate-nuclei-dns-shim";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [
        "ESTATE_DNS_SHIM_LISTEN=2001:4860:4860::8888,2001:4860:4860::8844"
        "ESTATE_DNS_SHIM_UPSTREAM=${vm.gateway}"
      ];
    };
  };

  users.groups.estate-scan = { };
  users.users.kestra-estate-scanner = {
    isSystemUser = true;
    group = "estate-scan";
    home = "${stateDir}/kestra";
    createHome = true;
    shell = "${pkgs.bash}/bin/bash";
    description = "Forced-command Kestra dispatch identity for estate scans";
    openssh.authorizedKeys.keys = [
      (builtins.readFile ../../../../config/ssh/kestra-estate-scanner.pub)
    ];
  };
  users.users.aether.extraGroups = [ "estate-scan" ];

  services.openssh.extraConfig = lib.mkAfter ''
    Match User kestra-estate-scanner
      AllowTcpForwarding no
      AllowAgentForwarding no
      PermitTTY no
      X11Forwarding no
      ForceCommand ${aetherScan}/bin/aether-scan
  '';

  environment.etc =
    {
      "ssh/auth_principals/kestra-estate-scanner".text = "\n";
      "estate-scanner/README".text = ''
        Estate scanner guest.
        Source identity: ${vm.ip}
        Dispatcher: aether-scan.bb via babashka (forced-command for kestra-estate-scanner)
        Nuclei templates: ${nucleiTemplatesRevision} (pinned; no auto-update)
        Naabu/httpx wrapped with -no-stdin -duc for non-interactive SSH/Kestra use.
        discover detaches via setsid; worker writes estate_scan.* in ClickHouse.
        ClickHouse password: /etc/estate-scanner/clickhouse-password (Ansible/SOPS).
        Do not add local OnCalendar scan schedules; Kestra is the schedule authority.
      '';
      "estate-scanner/runtime.json".source = runtimeConfigJson;
      "estate-scanner/naabu.yaml".text = ''
        no-stdin: true
        disable-update-check: true
        auth: false
        dashboard: false
        warm-up-time: 2
      '';
      "estate-scanner/nuclei-templates-revision".text = "${nucleiTemplatesRevision}\n";
      "estate-scanner/nuclei-config.yaml".text = ''
        # Estate-scanner Nuclei defaults (pin templates; no auto-update; no PDCP).
        auth: false
        dashboard: false
        disable-update-check: true
        no-interactsh: true
        silent: false
      '';
      "estate-scanner/nuclei-profiles/nuclei-daily.yml".text = ''
        # L7 HTTP only; skip noisy info/low and intrusive classes.
        severity:
          - medium
          - high
          - critical
        type:
          - http
        exclude-tags:
          - dos
          - fuzz
          - intrusive
      '';
      "estate-scanner/nuclei-profiles/nuclei-weekly.yml".text = ''
        severity:
          - info
          - low
          - medium
          - high
          - critical
        type:
          - http
        exclude-tags:
          - dos
          - fuzz
          - intrusive
      '';
      "estate-scanner/declared-targets.json".source = declaredTargetsJson;
    }
    // lib.listToAttrs (
      map (name: {
        name = "estate-scanner/profiles/${name}";
        value.text = ''
          profile: ${name}
          status: declared
        '';
      }) approvedProfiles
    );

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0770 root estate-scan -"
    "d ${profilesDir} 0750 root estate-scan -"
    "d ${runsDir} 0770 root estate-scan -"
    "d ${templatesDir} 0750 root estate-scan -"
    "d ${stateDir}/kestra 0750 kestra-estate-scanner estate-scan -"
    "d ${artifactsDir} 0770 root estate-scan -"
    "d ${stateDir}/nuclei-home 0750 root estate-scan -"
    "d ${stateDir}/nuclei-home/.config 0750 root estate-scan -"
    "d ${stateDir}/nuclei-home/.config/nuclei 0750 root estate-scan -"
  ];

  # Pin nuclei-templates into the guest state dir (immutable nix store symlink).
  system.activationScripts.estate-scanner-templates = {
    deps = [ "etc" ];
    text = ''
      mkdir -p ${templatesDir}
      ln -sfn ${nucleiTemplates} ${templatesDir}/${nucleiTemplatesRevision}
      ln -sfn ${templatesDir}/${nucleiTemplatesRevision} ${templatesDir}/current
      printf '%s\n' '${nucleiTemplatesRevision}' > ${templatesDir}/REVISION
      chown -R root:estate-scan ${templatesDir} || true
      # Clean Nuclei HOME so scans do not inherit operator ~/.config/nuclei
      # (which can point at a missing ~/nuclei-templates and hang on DNS).
      install -d -m 0750 -o root -g estate-scan ${stateDir}/nuclei-home/.config/nuclei
      printf '%s\n' '{"nuclei-templates-directory":"${templatesDir}/current"}' \
        > ${stateDir}/nuclei-home/.config/nuclei/.templates-config.json
      # Do not create .nuclei-ignore — an empty/comment-only file makes Nuclei
      # log "Could not parse nuclei-ignore file: EOF".
      rm -f ${stateDir}/nuclei-home/.config/nuclei/.nuclei-ignore
      # Symlink HOME config to immutable /etc — Nuclei rewrites a writable
      # config.yaml and restores auth:true (PDCP prompt / hang).
      ln -sfn /etc/estate-scanner/nuclei-config.yaml \
        ${stateDir}/nuclei-home/.config/nuclei/config.yaml
      chmod 0640 ${stateDir}/nuclei-home/.config/nuclei/.templates-config.json
      chown -R root:estate-scan ${stateDir}/nuclei-home
    '';
  };

  systemd.slices.estate-scan = {
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 20;
      MemoryMax = "3500M";
    };
  };
}
