# Historical telemetry migration

`migrate.bb` is the repo-conventional Babashka entry point. Its implementation is
Python **standard library only** (`migrate.py`): integer nanosecond timestamps,
SQLite commit journal, urllib HTTP, and subprocess SSH. Both runtimes are present
in `nix develop` (checked 2026-10-13). No package installation is required.

## Safety and cutoff

Do not insert until the repo-owned ClickStack tables exist in database `otel`.
The default operation writes; **always pass `--dry-run` for exploration**. Dry-run
prints up to `--samples` (default 5) complete JSONEachRow records to stdout, does
not contact ClickHouse, and does not create/update a checkpoint. Diagnostics go
to stderr. All source operations are GET/read-only SQL.

`--start` and `--cutoff` accept RFC3339 timestamps with timezone and up to nine
fractional digits, or integer epoch **nanoseconds**. Cutoff is the actual T0 when
dual-write started, not the migration execution time. Ranges are half-open:
`start <= event timestamp < T0`. Traces are fetched whole and filtered by each
span's start timestamp, not their retrieval time. Later-starting spans are not
inserted. Keep old pipelines running until exports and counts are reconciled.

Do not guess T0 from the sample commands below: those cutoffs were read-only
shape probes before dual-write. Pick one real T0 and use it consistently.

```bash
nix develop
export SSH_AUTH_SOCK=$HOME/.aether-toolbox/ssh/agent.sock
export CLICKHOUSE_PASSWORD=$(sops -d secrets/secrets.yml | yq .clickhouse.password)
# Set the approved real T0 and start in your shell before the write commands.
# Choose start at or after the destination TTL boundary unless preserving older
# history has been separately approved in the destination DDL.
```

## Loki logs

```bash
bb scripts/telemetry-migration/migrate.bb loki \
  --source https://loki.home.shdr.ch \
  --start 2026-10-13T10:50:00Z --cutoff 2026-10-13T10:50:01Z --dry-run

bb scripts/telemetry-migration/migrate.bb loki \
  --source https://loki.home.shdr.ch --start "$START" --cutoff "$T0" \
  --checkpoint loki.sqlite --interval 0.5 --limit 5000
```

Selector defaults to `{service_name=~".+"}`. Override `--selector` to split by
service if necessary, using disjoint selectors and separate checkpoint files.
The script requests the original lines, not `| json` (which would conflate parsed
body fields with telemetry attributes). The categorize-labels response's third
value element contains `structuredMetadata`. `service_name` becomes ServiceName;
known semconv names are reversed from Loki's underscore encoding, including
service.namespace, host.name, k8s.*, container.*, OS and telemetry SDK fields.
Provider/collector/domain stay resource attributes. Unknown names stay verbatim
in LogAttributes: underscore normalization is lossy and arbitrary custom resource
attributes cannot reliably be separated from log attributes. Severity uses the
original number/text if present, otherwise detected_level/level with canonical
OTel base severity numbers. Original metadata remains available in attribute maps.

One-hour chunks are paged by recursively splitting their start/end range when
`limit` saturates. This is deliberately safer than `last_timestamp + 1`: that
cursor loses tied timestamps at page boundaries. All windows are disjoint, and
saturation at one nanosecond fails loudly instead of discarding records. Increase
limit only on a fresh, nonoverlapping export; resume settings are immutable.

## Tempo traces

Tempo is **not published on the VM host**. A plain `ssh -L 3200:localhost:3200`
does not work against the current deployment. `--ssh` obtains the rootless
monitoring-stack infra PID and uses sudo nsenter into its network namespace for
read-only curl. This requires the existing aether SSH certificate and sudo access;
no VM files or container configuration are changed.

```bash
bb scripts/telemetry-migration/migrate.bb tempo \
  --source http://localhost:3200 --ssh aether@10.0.2.3 \
  --start 2026-10-13T10:00:00Z --cutoff 2026-10-13T11:00:00Z \
  --tenants aether --dry-run

bb scripts/telemetry-migration/migrate.bb tempo \
  --source http://localhost:3200 --ssh aether@10.0.2.3 \
  --start "$TRACE_START" --cutoff "$T0" --tenants aether,seven30,assay \
  --checkpoint tempo.sqlite
```

If running inside the pod network, omit `--ssh`; if exposing an authorized tunnel
into that network, pass its local URL without `--ssh`. From the VM host, retain
`--ssh aether@10.0.2.3` or use an equivalent pod-network execution context.
Refresh the tenant list from `config/tenants.yml` before execution (current defaults
are aether, seven30, assay). Each tenant uses X-Scope-OrgID. Tenant traces missing
service.namespace receive that namespace; conflicting namespace values fail
closed. aether preserves source resource attributes without assigning a tenant.

Search limits trigger recursive subdivision to one-second windows. A still-full
one-second window aborts: Tempo search has no cursor with which to prove complete
enumeration at that density. A full retrieved trace can overlap search windows;
the SQLite span-ID ledger prevents repeated inserts. Search must be complete for
the chosen tenant/windows; retain old Tempo until count reconciliation finishes.

Tempo OTLP JSON uses `batches` and base64 IDs; both that shape and `resourceSpans`
are accepted. Flatten resource/scope/spans, preserve duration in ns, all event and
link arrays, and output exporter strings `Server`, `Client`, `Internal`, etc.,
and `Unset`, `Ok`, `Error`. These match pdata `.String()` calls in contrib
[v0.156.0 exporter_traces.go](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.156.0/exporter/clickhouseexporter/exporter_traces.go).

## Greptime archive

Read-only evidence collected 2026-10-13:

- Config in `tofu/home/kubernetes/db_backups.tf` uses S3 bucket
  `greptime-telemetry`, root `aether`, and **no age TTL**. Generated credential keys
  in `tofu/home/secrets/greptime-credentials.yml` are database, ingest_user,
  ingest_password, grafana_user, grafana_password. Use only the readonly Grafana
  identity for exports. HTTP port 4000 is published on VM loopback; MySQL 4002 is
  only in the pod. `--ssh` works directly against HTTP loopback for Greptime.
- `SHOW CREATE TABLE opentelemetry_logs` confirms TIMESTAMP(9), body, trace/span
  IDs, severity, log/resource/scope JSON attributes and schema URLs. A real row at
  `1784332800007000000` (2026-07-18) has complete OTLP resource/log attributes.
  `SELECT ... WHERE timestamp < '2026-06-15T00:00:00Z' LIMIT 1` returned no rows.
  Loki still returns a real log at 2026-06-15T07:32:54.277385296Z. **No extra older
  Greptime log history was found for the current Loki boundary**; preserve the
  archive until final overlap checks. The log export mode is supplied in case
  that changes while migration is in progress.
- Metrics are individual Prometheus remote-write tables (SHOW TABLES includes
  up, ALERTS, node/ceph/DCGM metrics and exporter self-metrics), not OTLP metric
  type tables. `SHOW CREATE TABLE up` confirms TIMESTAMP(3), greptime_value,
  and string label/tag columns. `SELECT greptime_timestamp, greptime_value FROM
  up WHERE greptime_timestamp < '2026-09-13T00:00:00Z' LIMIT 1` returned
  `[1784334334003, 1.0]` (2026-07-18T00:25:34.003Z). **Older metrics migration is needed**.
- `podman exec prometheus promtool tsdb list /prometheus` shows the earliest
  persisted block minTime `1789257600000` ms. Use that measured boundary as
  `--overlap-before 1789257600000000000` ns, refreshed immediately before export.
  Prometheus `/status/tsdb` headStats.minTime is only the head, NOT the oldest
  retained block. Do not use it for overlap exclusion.
- An unrestricted min/max/count query on up timed out after 120 seconds; do not
  use a full-table count to estimate the archive. Narrow range probes succeeded.
  See `docs/exploration/telemetry-archive.md` for the July 18 rollout and no-TTL
  archive description. Tempo's authoritative tempo.yml retains 168h (7d), not
  the new ClickHouse trace TTL (30d).

```bash
export GREPTIME_USER=$(yq .grafana_user tofu/home/secrets/greptime-credentials.yml)
export GREPTIME_PASSWORD=$(yq .grafana_password tofu/home/secrets/greptime-credentials.yml)
GREPTIME_DB=$(yq .database tofu/home/secrets/greptime-credentials.yml)

bb scripts/telemetry-migration/migrate.bb greptime-metrics \
  --source http://localhost:4000 --ssh aether@10.0.2.3 --database "$GREPTIME_DB" \
  --table up --metric-type gauge --start "$ARCHIVE_START" --cutoff "$T0" \
  --overlap-before 1789257600000000000 --checkpoint greptime-up.sqlite --dry-run
# Remove --dry-run only after reviewing rows and destination DDL.

bb scripts/telemetry-migration/migrate.bb greptime-logs \
  --source http://localhost:4000 --ssh aether@10.0.2.3 --database "$GREPTIME_DB" \
  --start "$ARCHIVE_START" --cutoff "$T0" --overlap-before "$LOKI_OLDEST" \
  --checkpoint greptime-logs.sqlite --dry-run
```

Greptime exports stop at `min(T0, overlap-before)`. SQL range paging is adaptive,
with no unstable OFFSET sorting. Run one explicitly classified metric table at a
time with its own checkpoint. Inventory every table with SHOW TABLES and classify
against exporter metric HELP/TYPE metadata: `--metric-type gauge` for gauges,
`--metric-type sum` for cumulative monotonic counters. This is required, never
inferred from suffixes. Remote-write archived neither OTLP type, scope nor counter
start timestamps; sum rows therefore use cumulative temporality and epoch-zero
StartTimeUnix, preserving original counter samples rather than inventing resets.
Historical histogram `_bucket`, `_sum`, `_count` and summary/quantile series stay
losslessly as explicitly classified raw Prometheus components in gauge/sum tables;
they are not fabricated into incomplete OTLP histogram/summary rows. Preserve `le`
and `quantile` labels. Dashboards querying those historical components must account
for this difference from the new collector's native OTLP histograms. Service and
tenant resource attributes are reconstructed only from actual service labels.

> **Metrics via Greptime is disabled as a backfill path — do not use
> `greptime-metrics` for history.** The ClickHouse metrics tables have a 30-day
> TTL (`TTL toDateTime(TimeUnix) + toIntervalDay(30)`, verified 2026-10-13), so
> Greptime's older-than-30d metric rows (e.g. the 2026-07-18 samples above) would
> expire immediately on insert. Backfill metrics from Prometheus' own 30d TSDB
> instead (next section), which is exactly the window the TTL preserves. The
> `greptime-metrics` code remains only for completeness of the archive export;
> running it for pre-TTL-boundary ranges accomplishes nothing.

## Prometheus metrics backfill (30d TSDB -> ClickHouse)

Prometheus retains 30d (`storageRetention: 30d`, verified 2026-10-13) and the
ClickHouse metrics TTL is also 30d, so the backfillable window is exactly
`[T0 - 30d, T0)` per destination table. `prometheus` is a fifth backend in the
same script/checkpoint machinery; no inserts were performed while building it.

```bash
# Dry-run first: prints sample JSONEachRow rows, contacts Prometheus +
# ClickHouse read-only (agent_reader via /tmp/chq.sh fallback or
# CLICKHOUSE_USER/CLICKHOUSE_AGENT_PASSWORD), never inserts, no checkpoint.
bb scripts/telemetry-migration/migrate.bb prometheus \
  --source https://prometheus.home.shdr.ch \
  --start 2026-10-13T10:00:00Z --cutoff 2026-10-13T11:07:45Z \
  --metrics up --interval 0 --samples 3 --dry-run
# One gauge (up), one counter, one histogram, one summary:
#   --metrics node_cpu_seconds_total
#   --metrics caddy_http_request_duration_seconds
#   --metrics go_gc_duration_seconds
# Real run (writes!): omit --dry-run/--metrics, set start = T0-30d, one
# checkpoint per run; restart the identical command to resume.
bb scripts/telemetry-migration/migrate.bb prometheus \
  --source https://prometheus.home.shdr.ch \
  --start "$START" --cutoff "$T0" --checkpoint prometheus-metrics.sqlite
```

How it works:

- **Cutoff T0 is per table and queried at runtime**: the earliest `TimeUnix`
  already present in each of `otel_metrics_{gauge,sum,histogram,summary}`
  (measured 2026-10-13: gauge 11:07:45.34Z, sum 11:07:52.42Z, histogram/summary
  11:08:00.85Z). Effective end per table is `min(--cutoff, that table's T0)`;
  no row `>= T0` is ever emitted. `--cutoff` stays required as the operator's
  ceiling.
- **Reverse map is built at runtime**, never hard-coded: ClickHouse's current
  distinct `(MetricName, MetricUnit, IsMonotonic)` per table over
  `--map-hours` (default 24h) is translated back to Prometheus names with the
  live-schema rules (dots->underscores, unit suffix `s->seconds`, `By->bytes`,
  `1->ratio`, `{...}` dropped, `_total` for monotonic sums; names already
  ending in `_total`/`_count` are not double-suffixed), then matched against
  the live Prometheus `__name__` list and `/api/v1/metadata`. Measured
  2026-10-13: 3,890 ClickHouse metrics -> 4,121 Prometheus names claimed;
  23 ClickHouse metrics had no Prometheus counterpart (e.g. `executor.*`,
  `jvm.buffer.count`, `process.uptime` — OTLP-native names whose Prometheus
  form differs), and Prometheus series with no ClickHouse counterpart are
  **skipped and counted** on stderr, never guessed. `--metrics` (Prometheus or
  ClickHouse names, comma-separated) restricts a run for probing/resume splits.
- **Retrieval: `query_range` per metric name**, chunked by `--chunk-seconds`
  (default 1h) at `--step-seconds` (default 30s, the recorded scrape
  resolution). Remote-read was rejected: it needs protobuf+snappy (not stdlib)
  and measured no faster. Measured 2026-10-13 from this host: `up` 1d 0.54s,
  `node_cpu_seconds_total` 1d 2.7s, the 11,616-series
  `caddy_http_request_duration_seconds_bucket` family 1d 21s — about
  **1.5M samples/s** sustained. Checkpoint keys are per (chunk, table, metric),
  journaled exactly like the logs path (pending-payload ambiguity rules in the
  next section apply unchanged).
- **Labels**: `job` -> `ServiceName` + `ResourceAttributes['service.name']`
  (the part after `/` for `<namespace>/<name>` push jobs; `service_name` label
  wins when present), `instance` -> `ResourceAttributes['service.instance.id']`,
  `service_namespace` label -> resource `service.namespace`,
  `otel_scope_name`/`otel_scope_version` -> `ScopeName`/`ScopeVersion`; every
  other label -> `Attributes` verbatim. Resource attributes Prometheus never
  carried (host.name, k8s.*, ...) are left empty, not invented — backfilled
  rows are therefore thinner than live dual-write rows; dashboards must not
  assume `host.name` exists on pre-T0 data.
- **Types**: gauges -> `otel_metrics_gauge` (epoch of first sample as
  StartTimeUnix, matching live prometheus-receiver rows); monotonic sums ->
  `otel_metrics_sum` with `AggregationTemporality=2, IsMonotonic=1` and
  `StartTimeUnix` = first sample of each reset segment (segment breaks where
  the cumulative value drops); non-monotonic sums keep temporality 2 with
  `IsMonotonic=0`. Histograms: `_bucket{le}`/`_count`/`_sum` series are
  reassembled per label set and timestamp — `ExplicitBounds` = finite `le`
  values, `BucketCounts` = successive diffs of the cumulative `le` counts
  plus the `+Inf` remainder (verified: bucket counts sum to `Count`), `Count`
  from `_count`, `Sum` from `_sum`. Summaries: quantile series become
  `ValueAtQuantiles`, `Count`/`Sum` from the `_count`/`_sum` companions.
  Exemplars are empty (Prometheus HTTP API does not return them here).

Runtime estimate (measured, not extrapolated from guesses): Prometheus appends
~15.2k samples/s (`prometheus_tsdb_head_samples_appended_total`), i.e. ~1.3B
samples/day, ~39B over 30d as an upper bound including churn; the live head
holds ~498k series (the ~220k figure in earlier planning is the same order —
either way the transfer is bounded by samples, not series). At the measured
~1.5M samples/s that is **~7 hours of pure query_range transfer** for a full
30d backfill; with per-metric request overhead, JSON parsing, ClickHouse
inserts and pacing, plan **1–2 days** wall-clock for the full run, resumable
throughout. Start with a `--metrics` probe (minutes) before committing.

Verified dry-runs 2026-10-13 (all `--dry-run`, zero inserts): gauge `up`
(3 rows, ServiceName/resource/attributes as above), counter
`node_cpu_seconds_total` (Value 439374.24 at 10:00Z, temporality 2, monotonic,
segment StartTimeUnix), histogram `caddy_http_request_duration_seconds`
(BucketCounts sum == Count == 435, 11 bounds/12 buckets), summary
`go_gc_duration_seconds` (Count 9416, Sum 1.475, quantiles 0/0.25/0.5/0.75/1).

## Resuming and ambiguous writes

Each successful insert is synchronously committed, then checkpointed in SQLite.
Restart the **identical command/checkpoint** to skip completed chunks/spans.
Changing source, selector, tenant list, range, limit, chunk size or table is refused.
Use a new checkpoint only for a disjoint dataset, not to retry completed history.
Only one process may own a checkpoint; do not run concurrent exporters over the
same range/selector/table. Back up checkpoint files along with run commands.

Before an INSERT, the journal durably saves the exact JSONEachRow payload as
`pending`. If the process crashes or HTTP response is ambiguous, restart refuses
that batch. This is intentional: plain MergeTree cannot promise retry deduplication
without configured deduplication windows. Operator reconciliation must inspect
the pending payload and compare destination rows (logs can legitimately be identical;
use per-row occurrence counts, not a DISTINCT hash). Mark `done` only after proving
the whole batch exists; otherwise restore the destination to its pre-batch state
through an approved procedure and remove that pending journal entry. For traces,
also populate the `spans` ledger for reconciled TraceId:SpanId pairs in the same
SQLite transaction. Never blindly replay, and never assume HTTP failure means
zero committed rows. No script performs DELETE, schema mutation or retries.

## Capacity and ordering

Loki `/loki/api/v1/index/stats` for 2026-10-12 UTC with the default selector measured
**39,531,026 entries**, **41,732,417,536 bytes**, 2,609 streams and 9,848 chunks.
Extrapolating that one day to 120d gives about 4.74 billion rows and 5.0 TB indexed
uncompressed bytes, not a measured total dataset. At 5,000 rows/page and 0.5s source
pacing, the unrealistic best-case is about 5.5 days; recursive splits roughly
double query count (about 11 days), before HTTP/SSH, inserts, compression, historical
volume variation and query scanning costs. Plan **days to weeks**, measure an initial
small disjoint export and update the estimate. Trace search/fetch and cold S3 reads
add independent time. Use larger limits only within source server caps and agreed
memory limits. Existing recursive nodes are bounded by the response limit; a
single HTTP response and trace are held in memory.

Destination logs TTL is 120d, traces 30d and metrics 30d (all verified against
live `system.tables` 2026-10-13). Data older than those TTLs will expire after
insertion: decide archive preservation/TTL policy BEFORE retiring Greptime,
whose retention is unbounded. Greptime's July metric evidence is already
outside the 30d metrics TTL and cannot be preserved by insertion (see the
disabled Greptime metrics path above). Do not silently claim preservation
of unbounded history under bounded destination TTLs.

Ordering: record T0/start dual-write; deploy DDL; review real dry-runs and tenant
attributes; export old-only ranges; reconcile source/destination counts and inspect
pending checkpoints; preserve checkpoints and archive until accepted; only then
remove old backends. No INSERT or infrastructure mutation was performed while
creating these tools. The orchestrator should exercise checkpoint crash recovery,
ClickHouse JSONEachRow nested columns and type compatibility against staged DDL
before authorizing a production export.
