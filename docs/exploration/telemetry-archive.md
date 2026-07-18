# Telemetry Archive: GreptimeDB Deployment and Superseded ClickHouse Plan

This document records the deployed GreptimeDB archive and preserves the rejected
ClickHouse generic-metrics cold-tier experiment below. On 2026-07-18, GreptimeDB
replaced Thanos as the long-term metrics path and added a second sink for Loki-bound
logs. ClickHouse remains authoritative for network/IDS and VyOS data. See
[monitoring.md](../monitoring.md) for the current architecture.

The former ClickHouse archive went live on 2026-07-11 and went through two same-day
incidents before a third, soak-tested configuration. Its final experimental shape used
the pinned collector, repo-owned schema, a dedicated large-batch pipeline, and bounded
queues. Incident history:

1. **Memory**: collector heap blew past the 2 GiB `memory_limiter` (the exporterhelper
   *default* sending_queue — 1000 batches — was silently enabled and ballooned) → the
   limiter refused ALL ingest, k8s pipeline dead ~80 min. Fixed: limiter 4096/896 with
   `GOMEMLIMIT: 3GiB` below the soft-refusal line, bounded queue. **These guards stay.**
2. **CPU/throughput**: with the bounded queue (100), ClickHouse insert throughput could
   not keep pace — queue pinned at 100/100, ~7M points dropped in ~30 min (>50% of the
   stream), 2 consumers in continuous insert churn = sustained CPU creep on the 4-core
   VM, for an archive that was incomplete anyway. Detached again.

**Historical re-enable design (not deployed)** — the insert pattern was the root problem
(each 2048-point batch fans into 5 tiny per-type inserts; ClickHouse wants few, large
inserts):

- Dedicated archive pipeline (`metrics/archive`) with its own `batch/archive` processor
  (~50k points / 30s timeout) so ClickHouse receives large inserts
- Pinned collector image + repo-owned schema (`create_schema: false`) — unchanged preconditions
- Bounded queue + 60s retry (keep), consumers sized after a **local insert-throughput
  benchmark** against the same CH version — do not discover throughput in production a third time
- Success criteria: enqueue_failed rate = 0, queue depth < 20% steady, VM CPU delta < 5%,
  collector RSS < 3.2 GiB

Lesson encoded: archive fan-out must have its own bounded queue and must not become the
availability dependency for the live query path.

## Current state (verified live 2026-07-18)

- Prometheus retains 30 days locally for live PromQL and Grafana-managed alerts. Its
  remote-write path sends the exact post-scrape series to GreptimeDB.
- GreptimeDB v1.1.3 stores metrics and Loki-bound logs in the scoped
  `greptime-telemetry` SeaweedFS bucket. No archive age TTL is configured.
- Grafana exposes `Greptime Metrics Archive` through the built-in Prometheus datasource
  and `Greptime Telemetry Archive` through the built-in MySQL datasource for SQL/log
  exploration. Loki remains the primary LogQL datasource.
- Rollout checks observed 225 archived `up` series, 83,511 archived log rows in five
  minutes, fresh Parquet objects in SeaweedFS, and zero failed remote-write samples over
  five minutes.
- Loki retains 120 days and its 146 GiB dataset now lives beside GreptimeDB local state
  on the 1 TiB `local-fast` disk mounted at `/var/lib/telemetry`.
- Moving Loki reclaimed the root filesystem from 92% used to 33% used. The telemetry
  disk was 17% used after migration.
- Thanos Sidecar, Store Gateway, Query, and Compactor are stopped and their quadlet
  definitions, scrape job, and alerts are removed. The old `thanos-metrics` bucket is
  retained until historical data destruction is explicitly approved.
- ClickHouse remains authoritative for network/IDS data and VyOS observations. The OTEL
  collector does not write a generic metrics archive to ClickHouse.

## Historical ClickHouse cold-tier design

```text
hot (local NVMe, short)          ClickHouse archive                cold bytes
Prometheus 30d ── alerts/PromQL  metrics 365d ──┐ hot parts: local `default` disk
Loki 90d ──────── LogQL          extended-      ├ cold parts: cache-wrapped S3 disk
Tempo 7d ──────── traces         retention      │   on SeaweedFS `clickhouse-cold`
                                 tables (TBD) ──┘
```

Storage config shape (the cold **volume must reference the cache wrapper**, not the raw
s3 disk, or the cache is bypassed):

```xml
<disks>
  <s3_cold>
    <type>s3</type>
    <endpoint>http://{{ vm.seaweedfs.ip }}:{{ vm.seaweedfs.ports.s3 }}/clickhouse-cold/</endpoint>
    <access_key_id>…scoped identity…</access_key_id>
    <secret_access_key>…</secret_access_key>
  </s3_cold>
  <s3_cold_cache>
    <type>cache</type>
    <disk>s3_cold</disk>
    <path>/var/lib/clickhouse/s3_cache/</path>
    <max_size>10Gi</max_size>
  </s3_cold_cache>
</disks>
<policies>
  <tiered>
    <volumes>
      <hot><disk>default</disk></hot>
      <cold><disk>s3_cold_cache</disk></cold>
    </volumes>
    <move_factor>0</move_factor>  <!-- age moves via TTL only; move_factor is a
         space-pressure trigger, NOT an age threshold — enable deliberately or not at all -->
  </tiered>
</policies>
```

Failure-mode honesty (replaces the earlier too-soft claim): with SeaweedFS unreachable,
cold reads fail, TTL moves and cold-part merges stall, and ClickHouse start/restart
behavior with an unreachable disk must be **tested, not assumed**. Alerting still never
touches cold data; the drill below makes the rest empirical.

## Phase 1 — S3 disk + storage policy

### Preconditions (all hard)

- [ ] One-week steady-state metrics ingest rate measured
- [ ] Per-table TTL inventory + tier/stay/extend decision recorded in this doc
- [ ] **otel-collector image pinned** (ClickHouse already is; the collector is `:latest`
      and its ClickHouse metrics exporter is alpha) — rides A2 of
      [monitoring-stack-nix.md](monitoring-stack-nix.md)
- [ ] **Metrics schema ownership flipped to the repo**: dump current `SHOW CREATE` into
      the init-SQL dir, set `create_schema: false` on the exporter. Storage-policy surgery
      on tables an alpha exporter can re-create at whim is not acceptable
- [ ] **Scoped SeaweedFS identity** for `clickhouse-cold` via the existing
      `db_backups.tf` identities flow — the admin key is a cross-system god credential
      and is not a v1 shortcut
- [ ] Scratch-table drill on the tiered policy: forced `MOVE PARTITION TO VOLUME`,
      cached + cache-dropped reads, ClickHouse restart with S3 up, ClickHouse restart
      and merge/read behavior with SeaweedFS deliberately stopped

### Mechanics

1. Bucket `clickhouse-cold`; scoped credentials from SOPS via the tofu identities file.
2. Storage XML is a **template** (credentials!) rendered `0600`, `no_log: true` — and the
   ClickHouse container must **explicitly mount it**: the pod mounts individual config
   files, not the whole `config.d` directory, so a copied file is silently ignored.
   Container restart required (config.d storage changes are not hot-reloaded).
3. Per-table cutover, `metrics` first: for each table record the exact DDL with **both**
   clauses — e.g.
   `ALTER TABLE metrics.otel_metrics_gauge MODIFY SETTING storage_policy = 'tiered'`
   (legal: `tiered` is a superset containing `default`), then
   `ALTER TABLE … MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(30) TO VOLUME 'cold',
   toDateTime(TimeUnix) + toIntervalDay(365)` — move TTL AND explicit final delete TTL.
4. Soak a week on metrics; then only the tables the inventory marked for tiering.

### Verification

- `system.parts` disk distribution per table; `system.part_log` + server logs for move
  history (`system.moves` shows only in-flight moves — insufficient alone)
- Cold-history query spot-checks via Grafana; VM `df` trend; SeaweedFS dataset growth

### Rollback (order matters)

Move data home **before** touching the policy — the reverse is rejected because the old
policy doesn't contain the S3 disk: verify local headroom → `ALTER TABLE … MOVE PARTITION
… TO VOLUME 'hot'` until `system.parts` shows no cold-disk parts → then
`MODIFY SETTING storage_policy='default'`. Consequence: **tier zeek/suricata only while
local headroom can still absorb a full rollback of whatever has moved.**

## Phase 2 — logs join the archive

Collector fan-out `logs → clickhouse` (365d TTL, tiered policy from day one, repo-owned
DDL) alongside Loki, which stays the 90d hot LogQL path. Gate on measured volume.
Traces stay ephemeral.

## Phase 3 — offsite (optional, completes 3-2-1)

Candidate: add `clickhouse-cold` to the existing bucket→restic→Glacier sync. **Blocked on
measurement, not assumption**: the sync mirrors deletions and ClickHouse merges rewrite
whole parts, so restic pack churn could be substantial — measure object create/delete
rates and incremental pack growth during the metrics soak first. Native
`BACKUP TO S3(SeaweedFS)` remains a valid *logical* backup (schema mistakes, bad ALTERs)
but is not independent DR — same failure domain as the cold tier itself.

## Track B interaction (corrected)

The Nix migration must copy the **full ClickHouse volume regardless of tiering** — local
disk holds the S3-disk *metadata* files that map tables to remote objects; only the cache
directory is disposable. Tiering still shrinks the copy (cold bytes stay on SeaweedFS)
but "hot parts only" was wrong. Track B data table updated accordingly.

## Decisions record

| Alternative | Rejected because |
| --- | --- |
| Ceph RGW as cold backend | Ceph is the hot application tier (operator's storage taxonomy) |
| Grow monitoring VM disk to 512G | Feeds Track B data gravity instead of dissolving it |
| Replace ClickHouse with Databend, GreptimeDB, or Quickwit | Rejected because it would forfeit IDS schemas and the Argos data model; GreptimeDB is deployed alongside ClickHouse as a dedicated telemetry archive instead |
| Global default storage-policy flip | Table metadata pins policy; per-table ALTER keeps blast radius controllable |
| Admin S3 key for v1 | God credential across systems; scoped identity flow already exists |
| `move_factor`-driven tiering | Space-pressure trigger, not an age policy; TTL TO VOLUME is the explicit mechanism |

## Related

- [monitoring-stack-nix.md](monitoring-stack-nix.md) — A2 pinning; Track B copy semantics
- `../../../argos/VISION.md` — Argos persists compact features here; archive depth feeds baselines
- `../monitoring.md` — retention table
