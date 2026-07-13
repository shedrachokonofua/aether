# Estate scanner LXC — active discovery / fingerprint / Nuclei validation
# data plane on INFRA (VLAN 2, 10.0.2.13). See docs/exploration/estate-scanning.md.
#
# Scaffold only until Phase 1 provision is explicitly approved. CAP_NET_RAW for
# Naabu SYN mode must be proven on this unprivileged LXC before production scans;
# if the gate fails, replace with a small VM — do not widen the container boundary.
{ config, lib, pkgs, modulesPath, facts, ... }:

let
  vm = facts.vm.estate_scanner;
  stateDir = "/var/lib/estate-scanner";
  profilesDir = "${stateDir}/profiles";
  runsDir = "${stateDir}/runs";
  templatesDir = "${stateDir}/nuclei-templates";

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
    "gigahub"
    "aws-public"
    "aws-private"
    "gcp-public"
    "gcp-private"
  ];

  approvedStages = [
    "targets"
    "discover"
    "merge-diff"
    "fingerprint"
    "validate"
    "finalize"
    "status"
  ];

  aetherScan = pkgs.writeShellApplication {
    name = "aether-scan";
    runtimeInputs = with pkgs; [ coreutils jq ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      aether-scan — typed estate-scanner dispatcher (Kestra forced-command entrypoint)

      Usage:
        aether-scan targets snapshot <run-id> <profile>
        aether-scan discover <run-id> <target-group>
        aether-scan merge-diff <run-id>
        aether-scan fingerprint <run-id> <service-artifact>
        aether-scan validate <run-id> <service-artifact> <approved-profile>
        aether-scan finalize <run-id>
        aether-scan status <run-id> <stage> [target-group]

      Rejects caller-supplied shell, rates, templates, targets, and output paths.
      EOF
      }

      # When invoked via sshd ForceCommand, arguments arrive in SSH_ORIGINAL_COMMAND.
      if [[ $# -eq 0 && -n "''${SSH_ORIGINAL_COMMAND:-}" ]]; then
        # shellcheck disable=SC2086
        set -- $SSH_ORIGINAL_COMMAND
      fi

      require_run_id() {
        local run_id="$1"
        if [[ ! "$run_id" =~ ^[0-9a-fA-F-]{8,64}$ ]]; then
          echo "aether-scan: invalid run-id" >&2
          exit 2
        fi
      }

      require_profile() {
        local profile="$1"
        case "$profile" in
          ${lib.concatMapStringsSep "|" (p: p) approvedProfiles}) ;;
          *)
            echo "aether-scan: unknown or unapproved profile: $profile" >&2
            exit 2
            ;;
        esac
      }

      require_target_group() {
        local group="$1"
        case "$group" in
          ${lib.concatMapStringsSep "|" (g: g) approvedTargetGroups}) ;;
          *)
            echo "aether-scan: unknown or unapproved target-group: $group" >&2
            exit 2
            ;;
        esac
      }

      require_stage() {
        local stage="$1"
        case "$stage" in
          ${lib.concatMapStringsSep "|" (s: s) approvedStages}) ;;
          *)
            echo "aether-scan: unknown stage: $stage" >&2
            exit 2
            ;;
        esac
      }

      write_stub_status() {
        local run_id="$1"
        local stage="$2"
        local target_group="''${3:-}"
        local dir="${runsDir}/$run_id"
        mkdir -p "$dir"
        local status_file="$dir/status.json"
        jq -n \
          --arg run_id "$run_id" \
          --arg stage "$stage" \
          --arg target_group "$target_group" \
          --arg status "stubbed" \
          --arg message "dispatcher scaffold only; execution units not enabled" \
          --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{
            run_id: $run_id,
            stage: $stage,
            target_group: $target_group,
            status: $status,
            message: $message,
            updated_at: $updated_at
          }' > "$status_file"
        cat "$status_file"
      }

      if [[ $# -lt 1 ]]; then
        usage
        exit 2
      fi

      cmd="$1"
      shift

      case "$cmd" in
        targets)
          if [[ $# -lt 3 || "$1" != "snapshot" ]]; then
            usage
            exit 2
          fi
          require_run_id "$2"
          require_profile "$3"
          write_stub_status "$2" "targets" ""
          ;;
        discover)
          if [[ $# -lt 2 ]]; then usage; exit 2; fi
          require_run_id "$1"
          require_target_group "$2"
          write_stub_status "$1" "discover" "$2"
          ;;
        merge-diff)
          if [[ $# -lt 1 ]]; then usage; exit 2; fi
          require_run_id "$1"
          write_stub_status "$1" "merge-diff" ""
          ;;
        fingerprint)
          if [[ $# -lt 2 ]]; then usage; exit 2; fi
          require_run_id "$1"
          write_stub_status "$1" "fingerprint" ""
          ;;
        validate)
          if [[ $# -lt 3 ]]; then usage; exit 2; fi
          require_run_id "$1"
          require_profile "$3"
          write_stub_status "$1" "validate" ""
          ;;
        finalize)
          if [[ $# -lt 1 ]]; then usage; exit 2; fi
          require_run_id "$1"
          write_stub_status "$1" "finalize" ""
          ;;
        status)
          if [[ $# -lt 2 ]]; then usage; exit 2; fi
          require_run_id "$1"
          require_stage "$2"
          target_group="''${3:-}"
          if [[ -n "$target_group" ]]; then
            require_target_group "$target_group"
          fi
          status_file="${runsDir}/$1/status.json"
          if [[ -f "$status_file" ]]; then
            cat "$status_file"
          else
            write_stub_status "$1" "$2" "$target_group"
          fi
          ;;
        -h|--help|help)
          usage
          ;;
        *)
          echo "aether-scan: rejecting unknown operation or shell fragment: $cmd" >&2
          exit 2
          ;;
      esac
    '';
  };
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

  # Scanner binaries are pinned by the flake's nixpkgs input. Nuclei template
  # trees are pinned separately under ${templatesDir} and must not auto-update
  # immediately before a production scan.
  #
  # Naabu waits on stdin by default; non-interactive SSH/Kestra invocations then
  # hang forever in poll(). Wrap with -no-stdin and disable update/pdcp auth.
  environment.systemPackages = with pkgs; [
    aetherScan
    (symlinkJoin {
      name = "naabu-estate";
      paths = [ naabu ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/naabu \
          --add-flags "-no-stdin" \
          --add-flags "-duc"
      '';
    })
    nmap
    httpx
    nuclei
    jq
    yq-go
  ];

  users.groups.estate-scan = { };
  users.users.kestra-estate-scanner = {
    isSystemUser = true;
    group = "estate-scan";
    home = "${stateDir}/kestra";
    createHome = true;
    shell = "${pkgs.bash}/bin/bash";
    description = "Forced-command Kestra dispatch identity for estate scans";
  };
  users.users.aether.extraGroups = [ "estate-scan" ];

  # Dispatch identity: ForceCommand only. Public key material is added when the
  # Kestra egress path is verified (Phase 1 completion) — do not grant a shell.
  services.openssh.extraConfig = lib.mkAfter ''
    Match User kestra-estate-scanner
      AllowTcpForwarding no
      AllowAgentForwarding no
      PermitTTY no
      X11Forwarding no
      ForceCommand ${aetherScan}/bin/aether-scan
  '';

  # No interactive principals for the dispatch user; admin SSH uses aether/root.
  # Approved profile name markers (policy bodies land with the target compiler).
  environment.etc =
    {
      "ssh/auth_principals/kestra-estate-scanner".text = "\n";
      "estate-scanner/README".text = ''
        Estate scanner guest (scaffold).
        Source identity: ${vm.ip}
        Dispatcher: aether-scan (forced-command for kestra-estate-scanner)
        CAP_NET_RAW: prove on this unprivileged LXC before Naabu SYN production use.
        Do not add local OnCalendar scan schedules; Kestra is the schedule authority.
        Naabu is wrapped with -no-stdin -duc for non-interactive SSH/Kestra use.
      '';
      "estate-scanner/naabu.yaml".text = ''
        # Non-interactive defaults for estate-scanner (SSH / Kestra / systemd).
        no-stdin: true
        disable-update-check: true
        auth: false
        dashboard: false
        warm-up-time: 2
      '';
    }
    // lib.listToAttrs (
      map (name: {
        name = "estate-scanner/profiles/${name}";
        value.text = ''
          # Approved estate-scanner profile: ${name}
          # Policy body and rate limits are declared in Phase 1–2; the dispatcher
          # only accepts this name until then.
          profile: ${name}
          status: scaffold
        '';
      }) approvedProfiles
    );

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 root estate-scan -"
    "d ${profilesDir} 0750 root estate-scan -"
    "d ${runsDir} 0770 root estate-scan -"
    "d ${templatesDir} 0750 root estate-scan -"
    "d ${stateDir}/kestra 0750 kestra-estate-scanner estate-scan -"
    "d ${stateDir}/artifacts 0770 root estate-scan -"
  ];

  # Low priority defaults for future scan units (no OnCalendar — Kestra owns schedules).
  systemd.slices.estate-scan = {
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 20;
      MemoryMax = "3500M";
    };
  };
}
