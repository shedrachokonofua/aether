#!/usr/bin/env bash
# Newest-first parallel backfill driver for migrate.py.
#
#   run-parallel.sh <loki|prometheus> <worker-index> <worker-count> <days> <T0> [extra migrate.py args...]
#
# Splits [T0 - days, T0) into whole UTC-day windows, newest first, and processes
# every window where (window_index % worker-count) == worker-index. Newest-first
# matters: ClickHouse TTLs (logs 120d, metrics 30d) drop the oldest windows
# first, so the most valuable history lands before anything near the TTL edge.
# Each window is its own resumable migrate.py run with its own checkpoint file
# (migrate.py binds a checkpoint to one exact start/cutoff), so re-running the
# same command skips completed chunks and windows.
set -euo pipefail
backend=$1 worker=$2 workers=$3 days=$4 t0=$5
shift 5
here=$(cd "$(dirname "$0")" && pwd)
t0_epoch=$(date -u -d "$t0" +%s)
for ((i = 0; i < days; i++)); do
  ((i % workers == worker)) || continue
  cutoff_epoch=$((t0_epoch - i * 86400))
  start_epoch=$((cutoff_epoch - 86400))
  start=$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)
  cutoff=$(date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ)
  # migrate.py treats --cutoff as exclusive; for every window but the newest it
  # is just the window end. The real T0 bound is enforced by the newest window.
  echo "== $backend window $start .. $cutoff (worker $worker/$workers)"
  python3 "$here/migrate.py" "$backend" --start "$start" --cutoff "$cutoff" \
    --checkpoint "$here/${backend}-${start}.sqlite" "$@"
done
