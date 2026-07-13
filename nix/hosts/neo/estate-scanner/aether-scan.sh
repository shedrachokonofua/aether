# Estate-scanner typed dispatcher. Paths and allowlists are substituted at build time.
set -euo pipefail

STATE_DIR="@stateDir@"
RUNS_DIR="@runsDir@"
ARTIFACTS_DIR="@artifactsDir@"
DECLARED_TARGETS="@declaredTargets@"
LOCK_FILE="@lockFile@"
SCANNER_REVISION="@scannerRevision@"
NUCLEI_TEMPLATES_REVISION="@nucleiTemplatesRevision@"
NAABU="@naabu@"

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
if [[ $# -eq 0 && -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
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
    @approvedProfilesCase@) ;;
    *)
      echo "aether-scan: unknown or unapproved profile: $profile" >&2
      exit 2
      ;;
  esac
}

require_target_group() {
  local group="$1"
  case "$group" in
    @approvedTargetGroupsCase@) ;;
    *)
      echo "aether-scan: unknown or unapproved target-group: $group" >&2
      exit 2
      ;;
  esac
}

require_stage() {
  local stage="$1"
  case "$stage" in
    @approvedStagesCase@) ;;
    *)
      echo "aether-scan: unknown stage: $stage" >&2
      exit 2
      ;;
  esac
}

write_status() {
  local run_id="$1"
  local stage="$2"
  local target_group="${3:-}"
  local status="$4"
  local message="$5"
  local dir="${RUNS_DIR}/$run_id"
  mkdir -p "$dir"
  local status_file="$dir/status.json"
  jq -n \
    --arg run_id "$run_id" \
    --arg stage "$stage" \
    --arg target_group "$target_group" \
    --arg status "$status" \
    --arg message "$message" \
    --arg scanner_revision "$SCANNER_REVISION" \
    --arg nuclei_templates_revision "$NUCLEI_TEMPLATES_REVISION" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      run_id: $run_id,
      stage: $stage,
      target_group: $target_group,
      status: $status,
      message: $message,
      scanner_revision: $scanner_revision,
      nuclei_templates_revision: $nuclei_templates_revision,
      updated_at: $updated_at
    }' > "$status_file"
  cat "$status_file"
}

with_lock() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "aether-scan: another scan holds the exclusive lock" >&2
    exit 3
  fi
  "$@"
}

snapshot_targets() {
  local run_id="$1"
  local profile="$2"
  local dir="${RUNS_DIR}/$run_id"
  mkdir -p "$dir" "${ARTIFACTS_DIR}/$run_id"
  local manifest="$dir/targets.json"

  jq -n \
    --arg run_id "$run_id" \
    --arg profile "$profile" \
    --arg scanner_revision "$SCANNER_REVISION" \
    --arg nuclei_templates_revision "$NUCLEI_TEMPLATES_REVISION" \
    --arg frozen_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile declared "$DECLARED_TARGETS" \
    '{
      run_id: $run_id,
      profile: $profile,
      frozen_at: $frozen_at,
      scanner_revision: $scanner_revision,
      nuclei_templates_revision: $nuclei_templates_revision,
      vantage: "estate-scanner",
      targets: $declared[0].targets
    }' > "$manifest"

  ln -sfn "$manifest" "${ARTIFACTS_DIR}/$run_id/targets.json"
  write_status "$run_id" "targets" "" "succeeded" "declared target snapshot frozen"
}

discover_group() {
  local run_id="$1"
  local target_group="$2"
  local dir="${RUNS_DIR}/$run_id"
  local manifest="$dir/targets.json"
  local out_dir="${ARTIFACTS_DIR}/$run_id"
  mkdir -p "$dir" "$out_dir"

  if [[ ! -f "$manifest" ]]; then
    write_status "$run_id" "discover" "$target_group" "failed" "missing targets snapshot; run targets snapshot first"
    exit 4
  fi

  write_status "$run_id" "discover" "$target_group" "running" "discovery started" >/dev/null

  local list_file="$out_dir/discover-${target_group}-hosts.txt"
  local result_file="$out_dir/discover-${target_group}.jsonl"

  jq -r --arg g "$target_group" '
    .targets[]
    | select(.target_groups | index($g))
    | .address
  ' "$manifest" | sort -u > "$list_file"

  local count
  count="$(wc -l < "$list_file" | tr -d ' ')"
  if [[ ! -s "$list_file" ]]; then
    : > "$result_file"
    write_status "$run_id" "discover" "$target_group" "succeeded" "no declared targets for group"
    return 0
  fi

  # Conservative defaults from estate-scanning.md; profile rate policy comes later.
  # Top-100 ports on declared hosts only — not a blind /24 sweep.
  if ! "$NAABU" \
    -list "$list_file" \
    -top-ports 100 \
    -scan-type syn \
    -interface eth0 \
    -rate 100 \
    -c 10 \
    -timeout 3 \
    -retries 1 \
    -json \
    -silent \
    -nc \
    > "$result_file" 2>"$out_dir/discover-${target_group}.log"; then
    write_status "$run_id" "discover" "$target_group" "failed" "naabu exited non-zero; see discover-${target_group}.log"
    exit 5
  fi

  local open_count
  open_count="$(wc -l < "$result_file" | tr -d ' ')"
  write_status "$run_id" "discover" "$target_group" "succeeded" \
    "discovered ${open_count} open listeners across ${count} declared hosts (top-100)"
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
    with_lock snapshot_targets "$2" "$3"
    ;;
  discover)
    if [[ $# -lt 2 ]]; then usage; exit 2; fi
    require_run_id "$1"
    require_target_group "$2"
    with_lock discover_group "$1" "$2"
    ;;
  merge-diff)
    if [[ $# -lt 1 ]]; then usage; exit 2; fi
    require_run_id "$1"
    write_status "$1" "merge-diff" "" "stubbed" "merge-diff not implemented yet"
    ;;
  fingerprint)
    if [[ $# -lt 2 ]]; then usage; exit 2; fi
    require_run_id "$1"
    write_status "$1" "fingerprint" "" "stubbed" "fingerprint not implemented yet"
    ;;
  validate)
    if [[ $# -lt 3 ]]; then usage; exit 2; fi
    require_run_id "$1"
    require_profile "$3"
    write_status "$1" "validate" "" "stubbed" "validate not implemented yet; templates pinned at ${NUCLEI_TEMPLATES_REVISION}"
    ;;
  finalize)
    if [[ $# -lt 1 ]]; then usage; exit 2; fi
    require_run_id "$1"
    write_status "$1" "finalize" "" "stubbed" "finalize not implemented yet"
    ;;
  status)
    if [[ $# -lt 2 ]]; then usage; exit 2; fi
    require_run_id "$1"
    require_stage "$2"
    target_group="${3:-}"
    if [[ -n "$target_group" ]]; then
      require_target_group "$target_group"
    fi
    status_file="${RUNS_DIR}/$1/status.json"
    if [[ -f "$status_file" ]]; then
      cat "$status_file"
    else
      write_status "$1" "$2" "$target_group" "missing" "no status recorded for run"
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
