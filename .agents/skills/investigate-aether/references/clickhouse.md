# ClickHouse Telemetry (ClickStack)

ClickHouse (`otel` database) is the single telemetry store: metrics, logs, and
traces. Grafana (k8s) has ONLY the ClickHouse datasource (uid `clickhouse`,
`grafana_readonly`); HyperDX (`https://hyperdx.home.shdr.ch`, admin-only local
accounts) is the second UI over the same tables. Prometheus, Loki, Tempo,
Greptime, and Janus are removed — there is no PromQL/LogQL/TraceQL surface.

## Helper

```bash
G=.agents/skills/investigate-aether/scripts/grafana-read.bb
nix develop -c "$G" sql "SELECT ServiceName, argMax(Value, TimeUnix) AS value FROM otel.otel_metrics_gauge WHERE MetricName = 'up' AND TimeUnix > now() - INTERVAL 10 MINUTE GROUP BY ServiceName ORDER BY ServiceName LIMIT 20"
nix develop -c "$G" logs 'error'                       # otel_logs body substring search
nix develop -c "$G" logs 'Monitor #'                   # e.g. vigilant/Uptime Kuma lines
nix develop -c "$G" traces mnemo                       # spans by service name
nix develop -c "$G" traces 321b6f26cb1f6a69f41bcf533caea372  # spans by TraceId
```

`sql` accepts one comment-free read-only statement (`SELECT`/`SHOW`/`DESCRIBE`/
`DESC`/`EXPLAIN`). Always bound by time (`TimeUnix`/`Timestamp > now() -
INTERVAL ...`) and `LIMIT` — the metrics tables hold ~1B rows/day. The range
helpers default to the last hour; pass Unix seconds for explicit start/end.

## Tables

| Data | Table | Time column | Retention |
| --- | --- | --- | --- |
| Gauges | `otel.otel_metrics_gauge` | `TimeUnix` | 30d |
| Counters/sums | `otel.otel_metrics_sum` | `TimeUnix` | 30d |
| Histograms | `otel.otel_metrics_histogram` | `TimeUnix` | 30d |
| Logs | `otel.otel_logs` | `Timestamp` | 120d |
| Traces | `otel.otel_traces` | `Timestamp` | 30d |

Metrics columns: `MetricName, ServiceName, ResourceAttributes Map,
Attributes Map, Value` (histograms: `BucketCounts, ExplicitBounds, Count, Sum`).
`aether.namespace_contract` (columns `namespace, tier, owner, backup,
criticality, exposure`) replaces the old `aether:namespace_contract:info`
recording rule. Zeek/Suricata stay in the `zeek`/`suricata` databases (see
[Network security](network-security.md)).

## PromQL label → ClickHouse mapping (verified live)

- Metric name = `MetricName`. Prometheus-scraped metrics keep Prometheus names
  incl. suffixes (`node_cpu_seconds_total` in `otel_metrics_sum`, `up`,
  `kube_pod_status_phase` in gauge). OTLP-native metrics are dotted
  (`system.cpu.time` ↔ `system_cpu_time_seconds_total`, `k8s.pod.phase` ↔
  `k8s_pod_phase`): dots→underscores + unit suffix (`s`→`seconds`, `By`→`bytes`,
  `1`→ratio) + `_total` for monotonic sums; histogram `_bucket/_count/_sum`
  collapse to one `otel_metrics_histogram` row.
- `job` = `ServiceName`. For OTLP-pushed series the old
  `exported_job` is `Attributes['exported_job']`.
- `instance` = `ResourceAttributes['service.instance.id']` (empty for
  OTLP-native series).
- Every other label = `Attributes['<label>']` with the same name
  (`host_name`, `service_name`, `service_namespace`, `pod`, ... promoted
  exactly as Prometheus saw them). `otel_scope_name` = `ScopeName`.
- Gauges → `otel_metrics_gauge`; monotonic cumulative counters
  (`IsMonotonic=1, AggregationTemporality=2`) → `otel_metrics_sum`;
  histograms → `otel_metrics_histogram`.

## Semantics

- Gauge instant (Prometheus lookback): `argMax(Value, TimeUnix)` with
  `TimeUnix > now() - INTERVAL 5 MINUTE`, grouped by the series labels.
- `rate(x[5m])` / `increase()`: counters are cumulative with `StartTimeUnix`
  changing on reset. Per series (Attributes + instance + ServiceName +
  StartTimeUnix segment) use `deltaSumTimestamp(Value,
  toUnixTimestamp64Nano(TimeUnix))`, sum over segments, ÷ window seconds.
  Scrape interval is 30s (60s for SMART).
- `histogram_quantile`: cumulate per-bucket `BucketCounts` over
  `ExplicitBounds` (OTel histograms store per-bucket counts, not cumulative)
  and interpolate; do not use private-preview `timeSeries*` functions.
- `ALERTS` has no equivalent — use the Grafana `alertlist` panel or
  `GET /api/prometheus/grafana/api/v1/alerts` (what `aetherctl.bb status`
  uses). Activity-only metrics (e.g. `colony.agent.*`) may have no rows yet:
  derive the dotted name by the rule above and expect empty results.

## Logs (replaces LogQL)

- `ServiceName` = the old `service_name` label. k8s pods:
  `'<namespace>/<pod>'`; VMs: hostname; journald keeps the unit in
  `LogAttributes['journald.unit.name']`.
- Other labels are `ResourceAttributes['k8s.namespace.name']`,
  `ResourceAttributes['service.namespace']`, etc. (dots, not underscores).
- Line filters: `positionCaseInsensitive(Body, '...') > 0` or `match(Body, ...)`.
- JSON fields: `JSONExtractString(Body, 'field')`.
- `count_over_time([10m])` → `count()` with
  `Timestamp > now() - INTERVAL 10 MINUTE`. Avoid broad `ServiceName` scans.

## Traces (replaces TraceQL)

`otel.otel_traces`: `Timestamp, TraceId, SpanId, ParentSpanId, SpanName,
SpanKind, ServiceName, ResourceAttributes, SpanAttributes, Duration (ns),
StatusCode`. Trace coverage is application opt-in; absence is a coverage gap,
not proof of no traffic.

Sources: central OTel collector config, ClickStack DDL in
`ansible/playbooks/monitoring_stack/clickhouse/`, and
`tofu/home/kubernetes/grafana/` provisioning.
