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
    "cidr-services"
    "cidr-personal"
    "cidr-media"
    "cidr-guest"
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

  # Per-group UPPER bounds for fragile / client VLANs.
  # Do not put server CIDR groups here — that caps full-TCP below the profile rate.
  discoverGroupRates = {
    iot = 5;
    gigahub = 5;
    # Client VLANs: below server CIDR 100pps, high enough that a /24 top-100
    # finishes inside the daily window (5pps on /24 was multi-hour).
    cidr-personal = 25;
    cidr-media = 15;
    cidr-guest = 15;
  };

  # CIDR expansions for undeclared-host sweeps (not declared host lists).
  discoverCidrs = {
    cidr-infra = [ "10.0.2.0/24" ];
    cidr-services = [ "10.0.3.0/24" ];
    cidr-personal = [ "10.0.4.0/24" ];
    cidr-media = [ "10.0.5.0/24" ];
    cidr-guest = [ "10.0.7.0/24" ];
  };

  approvedStages = [
    "targets"
    "inventory-sync"
    "discover"
    "merge-diff"
    "fingerprint"
    "validate"
    "finalize"
    "status"
    "abandon"
    "reap-stale"
    "ingest-validate"
    "wait-stage"
  ];

  inventoryDir = "${stateDir}/inventory";

  # HTTPS inventory: generated before configure from tofu synthetic_probe_targets.
  # secrets/ is excluded from nix-builder rsync, so do not read tf-outputs here.
  inventoryDeclaredPath = ./inventory-declared.generated.json;
  inventoryDeclaredBody =
    if builtins.pathExists inventoryDeclaredPath
    then builtins.fromJSON (builtins.readFile inventoryDeclaredPath)
    else {
      generated_from = "missing inventory-declared.generated.json — run configure:estate-scanner";
      inventory_revision = "missing";
      entry_count = 0;
      entries = [ ];
    };

  inventoryDeclaredJson = pkgs.writeText "inventory-declared.json" (builtins.toJSON inventoryDeclaredBody);

  nucleiTemplatesRevision = "v10.4.5";
  nucleiTemplates = pkgs.fetchFromGitHub {
    owner = "projectdiscovery";
    repo = "nuclei-templates";
    rev = nucleiTemplatesRevision;
    hash = "sha256-6czf84bHyvHIT9rA2HUYqQe7lgODl4uRMP/8QepV3AU=";
  };

  # Daily: curated file allowlist (estate tripwires). Weekly: catalog dirs
  # (exposures/misconfiguration/exposed-panels) + selected CVEs. Entries may be
  # files or directories; both are symlinked from the pinned templates rev.
  dailyTemplateRels =
    lib.filter (s: s != "" && !(lib.hasPrefix "#" s)) (
      lib.splitString "\n" (builtins.readFile ./nuclei-daily-templates.txt)
    );
  nucleiDailyTemplates = pkgs.runCommand "estate-nuclei-daily" { } ''
    mkdir -p "$out"
    ${lib.concatMapStrings (rel: ''
      mkdir -p "$out/$(dirname ${lib.escapeShellArg rel})"
      ln -s ${nucleiTemplates}/${rel} "$out/${lib.escapeShellArg rel}"
    '') dailyTemplateRels}
  '';

  weeklyTemplateRels =
    lib.filter (s: s != "" && !(lib.hasPrefix "#" s)) (
      lib.splitString "\n" (builtins.readFile ./nuclei-weekly-templates.txt)
    );
  # Materialize catalog directories (cp -aL): Nuclei 3.11 does not follow
  # directory symlinks when walking -t paths. File entries stay as symlinks.
  nucleiWeeklyTemplates = pkgs.runCommand "estate-nuclei-weekly" { } ''
    mkdir -p "$out"
    ${lib.concatMapStrings (rel: ''
      mkdir -p "$out/$(dirname ${lib.escapeShellArg rel})"
      if [ -d ${nucleiTemplates}/${lib.escapeShellArg rel} ]; then
        cp -aL ${nucleiTemplates}/${lib.escapeShellArg rel} "$out/${lib.escapeShellArg rel}"
      else
        ln -s ${nucleiTemplates}/${lib.escapeShellArg rel} "$out/${lib.escapeShellArg rel}"
      fi
    '') weeklyTemplateRels}
  '';

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
    # Routed WireGuard site identities (prometheus scrape path; not public sweep).
    (mkTarget "aws-public-gateway-wg" "10.1.0.10")
    (mkTarget "gcp-uptime-monitor-wg" "10.2.0.10")
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

  # Nuclei 3.x defaults -auth true (PDCP) and embeds Google IPv6 DNS
  # (2001:4860:4860::8888). Without -auth=false it prompts on /dev/tty and hangs
  # under SSH. 3.11+ also blocks on open stdin unless -no-stdin (same class of
  # hang as naabu/httpx under SSH/ForceCommand). HOME disables PDCP config
  # rewrite; dns-shim answers the hardcoded resolvers; -r pins lab DNS so
  # public DoH/fallback cannot return CF tunnel IPs for *.home.shdr.ch
  # (1.1.1.1 → 172.64.80.1 CLOSE-WAIT hang).
  nucleiWrapped = pkgs.symlinkJoin {
    name = "nuclei-estate";
    paths = [ pkgs.nuclei ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/nuclei \
        --set HOME ${stateDir}/nuclei-home \
        --add-flags "-no-stdin" \
        --add-flags "-duc" \
        --add-flags "-disable-update-check" \
        --add-flags "-auth=false" \
        --add-flags "-r" \
        --add-flags "/etc/estate-scanner/resolvers.txt"
    '';
  };

  nucleiDnsShim = pkgs.writers.writeBabashkaBin "estate-nuclei-dns-shim" {
    check = "";
  } (builtins.readFile ./nuclei-dns-shim.bb);

  nucleiFixtureHttp = pkgs.writeShellApplication {
    name = "estate-nuclei-fixture-http";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./nuclei-fixture-http.py}
    '';
  };

  nucleiFixtureTemplate = ./nuclei-fixtures/aether-estate-scan-fixture.yaml;

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
    nuclei_daily_templates_dir = "/etc/estate-scanner/nuclei-daily";
    nuclei_weekly_templates_dir = "/etc/estate-scanner/nuclei-weekly";
    lock_file = lockFile;
    declared_targets = "/etc/estate-scanner/declared-targets.json";
    inventory_declared = "/etc/estate-scanner/inventory-declared.json";
    inventory_dir = inventoryDir;
    inventory_revision = inventoryDeclaredBody.inventory_revision;
    # Fixed CT query — ForceCommand must not accept caller-supplied CT URLs.
    ct_query_url = "https://crt.sh/?q=%25.shdr.ch&output=json";
    ct_timeout_ms = 60000;
    inventory_max_names = 500;
    # Hostname L7: internal only for daily Nuclei (public/tunnel via CF hangs CLOSE-WAIT).
    inventory_l7_exposures = [ "internal" ];
    # Declared accepted findings — write-findings! stamps state=suppressed at
    # insert so the next run does not re-open them. Match is on the same
    # finding_key inputs (template|host|port|matcher). Keep prometheus-metrics
    # in the daily template pack as a drift tripwire for unexpected hosts.
    accepted_findings = [
      {
        template_id = "prometheus-metrics";
        host = "10.0.2.6";
        port = 8000;
        matcher = "";
        reason = "apprise metrics on scrape VLAN (accepted)";
      }
      {
        template_id = "aether-estate-scan-fixture";
        host = "127.0.0.1";
        port = 18080;
        matcher = "fixture-marker";
        reason = "controlled canary";
      }
    ];
    naabu = "${naabuWrapped}/bin/naabu";
    httpx = "${httpxWrapped}/bin/httpx";
    nuclei = "${nucleiWrapped}/bin/nuclei";
    curl = "${pkgs.curl}/bin/curl";
    scanner_revision = "estate-scanner-nixos";
    nuclei_templates_revision = nucleiTemplatesRevision;
    approved_profiles = approvedProfiles;
    approved_target_groups = approvedTargetGroups;
    approved_stages = approvedStages;
    approved_validate_artifacts = [
      "fingerprint.jsonl"
      "services-all.jsonl"
      "services-changed.jsonl"
      "inventory-https.txt"
      "validate-targets.txt"
    ];
    discover_profiles = discoverProfiles;
    discover_group_rates = discoverGroupRates;
    discover_cidrs = discoverCidrs;
    # Cap Nuclei wall time so Kestra concurrency:1 cannot queue forever.
    # Hostname inventory (~95) + IP fingerprint (~23) ≫ prior 23-URL ~72m baseline.
    validate_timeout_ms = 28800000; # 8 hours
    fixture_url = "http://127.0.0.1:18080/";
    fixture_templates_dir = "/etc/estate-scanner/nuclei-fixtures";
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

  # Never fall back to public DNS — 1.1.1.1 returns Cloudflare tunnel IPs for
  # *.home.shdr.ch (172.64.80.1) and Nuclei hangs in CLOSE-WAIT on those edges.
  services.resolved.fallbackDns = [
    vm.gateway
    facts.vm.adguard.ip
    facts.vm.adguard_secondary.ip
  ];

  environment.systemPackages = [
    aetherScan
    naabuWrapped
    httpxWrapped
    nucleiWrapped
    nucleiDnsShim
    nucleiFixtureHttp
    pkgs.nmap
    pkgs.babashka
    pkgs.util-linux # setsid for detached discover workers
    pkgs.curl
    pkgs.jq
    pkgs.yq-go
  ];

  systemd.services.estate-nuclei-fixture-http = {
    description = "Controlled Nuclei-positive HTTP canary for estate-scanner";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${nucleiFixtureHttp}/bin/estate-nuclei-fixture-http";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [
        "ESTATE_FIXTURE_BIND=127.0.0.1"
        "ESTATE_FIXTURE_PORT=18080"
      ];
    };
  };

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
        Declared HTTPS inventory: /etc/estate-scanner/inventory-declared.json
          (baked from tofu synthetic_probe_targets; refresh via configure:estate-scanner).
        inventory-sync refreshes CT + DNS resolve into ${inventoryDir}.
        Do not add local OnCalendar scan schedules; Kestra is the schedule authority.
      '';
      "estate-scanner/runtime.json".source = runtimeConfigJson;
      "estate-scanner/inventory-declared.json".source = inventoryDeclaredJson;
      "estate-scanner/naabu.yaml".text = ''
        no-stdin: true
        disable-update-check: true
        auth: false
        dashboard: false
        warm-up-time: 2
      '';
      "estate-scanner/nuclei-templates-revision".text = "${nucleiTemplatesRevision}\n";
      "estate-scanner/resolvers.txt".text = ''
        ${vm.gateway}
        ${facts.vm.adguard.ip}
        ${facts.vm.adguard_secondary.ip}
      '';
      "estate-scanner/nuclei-config.yaml".text = ''
        # Estate-scanner Nuclei defaults (pin templates; no auto-update; no PDCP).
        auth: false
        dashboard: false
        disable-update-check: true
        no-interactsh: true
        silent: false
      '';
      "estate-scanner/nuclei-profiles/nuclei-daily.yml".text = ''
        # L7 HTTP only. Include info/low so curated panel detects fire; noise
        # control is the daily file allowlist, not severity gating.
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
        # No unauthenticated kubelet on Talos (TLS :10250 only). Prior hits were
        # ceph-csi nodeplugin metrics/pprof on :8080/:8081 (since disabled).
        exclude-templates:
          - http/cves/2019/CVE-2019-11248.yaml
      '';
      "estate-scanner/nuclei-profiles/nuclei-weekly.yml".text = ''
        # Broader catalog dirs (exposures/misconfig/panels). Same safety excludes;
        # no default-logins / code / headless in the weekly pack paths.
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
        # Same as daily — Talos has no unauthenticated kubelet debug port.
        exclude-templates:
          - http/cves/2019/CVE-2019-11248.yaml
      '';
      "estate-scanner/nuclei-fixtures/aether-estate-scan-fixture.yaml".source = nucleiFixtureTemplate;
      "estate-scanner/nuclei-daily".source = nucleiDailyTemplates;
      "estate-scanner/nuclei-weekly".source = nucleiWeeklyTemplates;
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
    "d ${inventoryDir} 2770 root estate-scan -"
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
      # Inventory dir must be writable by kestra-estate-scanner (estate-scan group).
      install -d -m 2770 -o root -g estate-scan ${inventoryDir}
      chown -R root:estate-scan ${inventoryDir} || true
      chmod -R g+rw ${inventoryDir} || true
      find ${inventoryDir} -type d -exec chmod g+s {} + || true
      install -d -m 0770 -o root -g estate-scan ${stateDir}/tmp
      # Clean Nuclei HOME so scans do not inherit operator ~/.config/nuclei
      # (which can point at a missing ~/nuclei-templates and hang on DNS).
      install -d -m 0750 -o root -g estate-scan ${stateDir}/nuclei-home/.config/nuclei
      install -d -m 0770 -o root -g estate-scan ${stateDir}/nuclei-home/.config/uncover
      # Drop stale LevelDB scratch dirs that stall Nuclei startup.
      rm -rf /tmp/nuclei* ${stateDir}/tmp/nuclei* 2>/dev/null || true
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
