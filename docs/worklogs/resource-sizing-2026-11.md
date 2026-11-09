# Three-month resource-sizing review (2026-11-09)

## Result

The requested interval is `[2026-08-09 21:09:56, 2026-11-09 21:09:56)`
UTC: three calendar months, or 92 days. Recovering the retired Greptime archive
extends the analysis beyond ClickHouse's live 30-day retention. The earlier
seven-day proposals are superseded by the measurements below.

| Workload | Current main-container memory request | Three-month-window p99 | Largest raw observation | Proposed request | History qualification |
| --- | ---: | ---: | ---: | ---: | --- |
| Orion QA browser | 2 GiB | 1.201 GiB | 1.934 GiB | Keep 2 GiB | Only October 24-November 9 observed; not a three-month measurement |
| Colony daemon | 2 GiB | 0.955 GiB | 3.485 GiB | Keep 2 GiB | First observation August 16; gaps remain |
| OpenWebUI | 2 GiB | 0.844 GiB | 2.177 GiB | 1.5 GiB | Observations span August 9-November 9; gaps remain |
| SnapOtter | 3.5 GiB | 0.773 GiB | 1.109 GiB | 2 GiB | Observations span August 9-November 9; separate 2 GiB init floor |

These are recommendations, not deployed changes. The proposed per-pod memory
request reductions sum to **2 GiB** (0.5 GiB for OpenWebUI and 1.5 GiB for
SnapOtter), not the earlier 4.75 GiB. Fleet savings depend on replica counts.
Keep all existing limits.
Requests are scheduling reservations, not usage caps: OpenWebUI and Colony have
observed bursts above the proposed or retained requests. A p99 is not a maximum
or a guarantee against memory pressure.

The QA-browser proposal of 768 MiB is withdrawn because it is below even the
available-history p99. The Colony proposal of 1 GiB is also withdrawn: it leaves
little headroom above p99 and ignores much larger observed bursts. SnapOtter's
sequential GPU-package init container requests 2 GiB separately; application
working-set measurements cannot justify lowering that initialization floor.

## Coverage and gaps

Missing observations remain missing, not zero usage. A query spanning three
months does not establish three months of uninterrupted measurements, and no
workload's creation date is inferred from its first retained observation.

| Workload | First observation (UTC) | Dates with observations | Active pod/container five-minute observations | Requested-window five-minute bins covered | Largest sample gap |
| --- | --- | ---: | ---: | ---: | ---: |
| Orion QA browser | 2026-10-24 02:13:51.958 | 17 | 4,834 | 18.24% | 19 minutes |
| Colony daemon | 2026-08-16 02:22:36.361 | 85 | 24,003 | 90.07% | 46.7 hours |
| OpenWebUI | 2026-08-09 21:10:33.437 | 92 | 25,818 | 97.35% | 41.5 hours |
| SnapOtter | 2026-08-09 21:10:05.801 | 93 | 25,560 | 96.45% | 19.4 hours |

The interval intersects 93 UTC dates because both boundary dates are partial.
Date counts are not counts of complete days. Percent coverage uses distinct
workload/time bins, not pod counts, so a rolling deployment cannot inflate it.
First observations and maxima use the original samples; percentile calculation
uses the regularized observations described below. Gaps may reflect downtime or
missing telemetry; this review does not assume which.

## Sources verified directly

- Grafana's Viewer API and datasource UID `clickhouse` query the live
  `otel.otel_metrics_gauge` and `otel.otel_metrics_sum` tables. Live
  `system.tables.create_table_query` confirms a 30-day TTL on all five metrics
  tables, with `ttl_only_drop_parts = 1`.
- The retained SeaweedFS bucket `greptime-telemetry` contains physical metric
  Parquet files under `aether/data/greptime/public/1025/1025_0000000000/data/`.
  All 327 file footers were inspected through ranged GETs: their timestamp
  bounds span July 18 00:01:10.583 through October 13 13:04:34.009 UTC.
  These are whole-store bounds, not claims of uninterrupted candidate coverage.
- Read-only inspection of the monitoring VM's retained Greptime metadata maps
  logical table 2999 to `container_memory_working_set_bytes`, and table 2964 to
  `container_cpu_usage_seconds_total`. Sparse primary keys carry the logical
  table identity and original namespace, container, pod, and instance labels.
- The capacity export at
  `s3://aether-db-dumps/capacity-prometheus/2026-10-24/` was checked directly.
  Listing the parent prefix returned only that export. Its `manifest.json`
  matches `manifest.sha256`:
  `fdd567dce343c2629b0799692949aa668e19969296f7b371cbcc54b885c40c24`.
  Container CPU and memory each have 61 chunks spanning September 24 06:05
  through October 24 09:55 UTC at five-minute evaluation resolution. It does not
  supply August observations and was not mixed into the final memory dataset.
- The retained Thanos bucket has six block prefixes. Five readable `meta.json`
  files cover June 25-June 30; the sixth metadata object returns 404. Those
  readable blocks do not supply the requested August-November period.

All archive access was read-only. No Greptime service was restarted, no data was
inserted into live ClickHouse, and no retention or infrastructure was changed.

## Memory calculation

The metric is a container's working set in bytes, not RSS, a pod sum, or a limit.
Selectors include every matching pod generation in the interval:

- `coder`, container `playwright`, pod prefix `orion-qa-browser-`.
- `colony`, container `colonyd`.
- `openwebui`, container `openwebui`.
- `snapotter`, container `snapotter`.

Recovery uses ranged Parquet reads, pruning row groups by logical metric identity
and timestamp bounds before selecting matching container labels. The 111.6 GB
physical metric store was not downloaded in full.

All 652,937 row groups in the 241 archive files overlapping the recovery
interval have both primary-key and timestamp min/max statistics. No group was
excluded merely because pruning statistics were absent. The 68 nonempty initial
extracts and 27 nonempty handoff extracts exactly match their extraction
manifests; no stale cached files enter the memory calculation.

Use archive observations before `2026-10-13 11:07:45.340` UTC and live scraped
observations at or after that handoff. This avoids counting the same period in
two stores, and recovers the partially migrated October 10-12 days instead of
assuming that the oldest live sample marks complete coverage.

Archive duplicates are keyed by exact primary key and timestamp, retaining the
highest sequence number and only put operations (`__op_type = 1`). This reduces
516,220 selected rows to 512,311; duplicate keys have zero conflicting values.
Reject null and non-finite values. The final calculation includes 236,243
original Colony, 254,804 OpenWebUI, 252,016 SnapOtter, and 48,111 QA-browser
observations after the archive/live handoff.

Scrape cadence differs across the historical sources. To avoid overweighting
periods with denser sampling, take the last observed value for each active
pod/container in each five-minute UTC bin, across all pod generations. Do not
interpolate absent bins. Compute the p99 over those observations as the upper
order statistic (`numpy.quantile(values, 0.99, method="higher")`). This is not an
average of daily or source-specific percentiles, and the per-pod percentile is
not a concurrent sum of replicas.

As a sensitivity check, p99 over every original observation without five-minute
regularization is 1.206 GiB for the QA browser, 0.955 GiB for Colony, 0.844 GiB
for OpenWebUI, and 0.773 GiB for SnapOtter. Maxima in the result table are from
those original observations, so five-minute sampling does not hide known bursts.
The regularized observation tuples have SHA256:
`2bd60fbf8d592da6925c2b46ccccc250863d76c3a9a369e1950f40f556eafc57`.

Codec interpretation follows the official
[GreptimeDB sparse-key implementation](https://github.com/GreptimeTeam/greptimedb/blob/v1.1.3/src/mito-codec/src/row_converter/sparse.rs)
and [operation enum](https://github.com/GreptimeTeam/greptime-proto/blob/f5ab772b697b571e2c27b7d74fab98bac27046ae/proto/greptime/v1/wal.proto):
`PUT = 1`, `DELETE = 0`.

## CPU cross-check

The earlier CPU cautions used seven-day p95 values. The recovered-window p99
uses the original `container_cpu_usage_seconds_total` counter, filtered to the
`cpu=total` series, rather than pooling native instantaneous CPU gauges with
historical counters.

| Workload | Three-month-window p99 (cores) | Largest observed five-minute rate (cores) | Five-minute bins covered |
| --- | ---: | ---: | ---: |
| Jellyfin | 1.096 | 10.264 | 99.20% |
| ComfyUI | 0.017 | 3.656 | 92.31% |

Both have counter-derived rate observations from August 9 through November 9.
The low ComfyUI p99 describes mostly idle time, not an adequate reservation for
an active inference job. Do not treat either p99 as a CPU limit or automatically
lower CPU requests from this table; workload concurrency and contention matter.

Deduplicate archive counters by primary key and timestamp, retain the highest
sequence put, and partition archive/live observations at the same handoff as
memory. There are 361,568 selected archive observations before deduplication,
358,952 after, and zero conflicting values. The 96 nonempty counter extracts
exactly match their extraction manifest.

Compute reset-corrected positive counter increases per exact container series
within each five-minute UTC evaluation window, divided by the elapsed time
between its first and last observed samples. Require at least two samples and
skip windows containing an interior sample gap over 120 seconds. Then compute
the upper-order-statistic p99 over active windows across pod generations.
This does not extrapolate to window edges as Prometheus `rate()` does, and is
not directly equivalent to the former instantaneous native CPU gauge p99.
The calculation yields 26,294 Jellyfin and 24,460 ComfyUI series/windows;
coverage counts distinct workload/time bins, not overlapping replicas.

## Reproducing the live portion

Use the repo's read-only Grafana helper in the Nix dev shell. Bound both the time
range and row limit; fetch individual workloads separately when exporting raw
observations. A live-only percentile is not the final three-month result.

```bash
nix develop --command .agents/skills/investigate-aether/scripts/grafana-read.bb sql "$(cat <<'SQL'
SELECT
    Attributes['namespace'] AS namespace,
    Attributes['container'] AS container,
    toString(min(TimeUnix)) AS first_utc,
    toString(max(TimeUnix)) AS last_utc,
    count() AS samples,
    quantileExact(0.99)(Value) / 1073741824 AS live_only_p99_gib
FROM otel.otel_metrics_gauge
WHERE MetricName = 'container_memory_working_set_bytes'
  AND TimeUnix >= toDateTime('2026-10-10 00:04:44', 'UTC')
  AND TimeUnix < toDateTime('2026-11-09 21:09:56', 'UTC')
  AND (
    (Attributes['namespace'] = 'coder'
      AND Attributes['container'] = 'playwright'
      AND startsWith(Attributes['pod'], 'orion-qa-browser-'))
    OR (Attributes['namespace'] = 'colony' AND Attributes['container'] = 'colonyd')
    OR (Attributes['namespace'] = 'openwebui' AND Attributes['container'] = 'openwebui')
    OR (Attributes['namespace'] = 'snapotter' AND Attributes['container'] = 'snapotter')
  )
GROUP BY namespace, container
ORDER BY namespace
LIMIT 8
SQL
)"
```

The live TTL continues to expire data; re-running that query later cannot
recreate expired observations. Preserve or query the cold archive separately,
without restoring its records into the normal 30-day-TTL metrics tables.
