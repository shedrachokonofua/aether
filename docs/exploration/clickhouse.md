# ClickHouse Exploration

Exploration of ClickHouse as a columnar analytics database for high-volume log storage and long-term metrics retention.

## Goal

Address limitations with current log storage for high-volume, analytics-heavy workloads:

1. **Zeek logs** — 12M+ logs/day, need per-IP analytics, SQL queries
2. **Long-term metrics** — Prometheus retention is limited (15 days), need months/years
3. **High-cardinality data** — Per-container, per-IP metrics that kill Prometheus
4. **Cost-effective storage** — Better compression than Loki for structured data

## Current State

| Aspect            | Current              | Gap                                         |
| ----------------- | -------------------- | ------------------------------------------- |
| Zeek logs         | Loki                 | ~12M logs/day, expensive queries, no SQL    |
| Suricata logs     | Loki                 | ~4M logs/day, works fine for alert-focused  |
| Long-term metrics | Prometheus (15 days) | No historical trending beyond 2 weeks       |
| High-cardinality  | Prometheus           | Cardinality limits, memory pressure         |
| Per-IP analytics  | Loki (slow)          | Count queries take seconds, no aggregations |

### Log Volume Analysis

| Source    | Daily Volume | Daily Entries | Primary Log Types          |
| --------- | ------------ | ------------- | -------------------------- |
| Zeek      | ~1.2 GB      | ~12.6M        | conn (70%), dns, http, ssl |
| Suricata  | ~400 MB      | ~4M           | alerts, flow, http, dns    |
| Other VMs | ~200 MB      | ~2M           | journald, application logs |
| **Total** | **~1.8 GB**  | **~19M**      |                            |

Loki handles ~19M logs/day but Zeek queries are slow due to:

- Label cardinality (per-IP labels not feasible)
- LogQL isn't optimized for aggregations
- Full scans for analytics queries

## Why ClickHouse

ClickHouse is a columnar OLAP database optimized for analytics on large datasets.

| Feature            | Benefit for Aether                          |
| ------------------ | ------------------------------------------- |
| Columnar storage   | Read only needed columns, 10-100x faster    |
| Compression        | 10-20x compression ratio on structured logs |
| SQL                | Familiar, powerful, no LogQL limitations    |
| Materialized views | Pre-aggregate per-IP stats automatically    |
| TTL                | Per-table retention, tiered storage         |
| OTEL native        | Direct export from OTEL Collector           |
| Grafana plugin     | Official plugin with OTEL integration       |

### Compression Comparison

| Store      | 1 Day Zeek (~12M rows) | vs Raw | vs Loki |
| ---------- | ---------------------- | ------ | ------- |
| Raw JSON   | ~3-4 GB                | 1x     | —       |
| Loki       | ~1-1.5 GB              | ~3x    | 1x      |
| ClickHouse | ~500 MB - 1 GB         | ~4-6x  | ~2-3x   |

**Storage win is modest (~2-3x vs Loki).** The real gain is query performance.

### Query Performance

| Query Type                    | Loki        | ClickHouse (typed) |
| ----------------------------- | ----------- | ------------------ |
| Count alerts by severity      | 2-5s        | <100ms             |
| Top 10 talkers by bytes       | 10-30s      | <200ms             |
| Per-IP connection count (24h) | Timeout/OOM | <500ms             |
| Aggregate by hour over 7 days | Minutes     | <1s                |

**Typed columns vs Map access:**

| Query        | Map Access (`LogAttributes['field']`) | Typed Column           |
| ------------ | ------------------------------------- | ---------------------- |
| Filter by IP | ~2-5s (string comparison)             | <100ms (IPv4 native)   |
| Sum bytes    | ~3-8s (cast every row)                | <200ms (UInt64 native) |
| GROUP BY IP  | ~5-10s                                | <500ms                 |

Typed columns via MVs provide 10-50x speedup over Map access.

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Monitoring Stack (16GB)                              │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                        Data Ingest Layer                             │   │
│   │                                                                      │   │
│   │   OTEL Collector ◄──── Zeek (clickhouse exporter)                   │   │
│   │                  ◄──── Suricata (loki exporter + metrics)           │   │
│   │                  ◄──── All VMs (prometheus, loki)                   │   │
│   └──────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│              ┌─────────────────────┼─────────────────────┐                  │
│              ▼                     ▼                     ▼                  │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐        │
│   │   ClickHouse     │  │      Loki        │  │   Prometheus     │        │
│   │                  │  │                  │  │                  │        │
│   │  • Zeek logs     │  │  • Suricata      │  │  • Metrics       │        │
│   │  • Flow data     │  │  • App logs      │  │  • Suricata      │        │
│   │  • Long-term     │  │  • System logs   │  │    counts        │        │
│   │    metrics       │  │                  │  │                  │        │
│   │                  │  │  Retention: 14d  │  │  Retention: 15d  │        │
│   │  Retention: 30d  │  │                  │  │                  │        │
│   └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘        │
│            │                     │                     │                   │
│            └─────────────────────┼─────────────────────┘                   │
│                                  ▼                                          │
│                        ┌──────────────────┐                                 │
│                        │     Grafana      │                                 │
│                        │                  │                                 │
│                        │  • ClickHouse DS │                                 │
│                        │  • Loki DS       │                                 │
│                        │  • Prometheus DS │                                 │
│                        └──────────────────┘                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### ClickHouse Server

Single-node deployment (cluster overkill for homelab scale).

| Setting     | Value                 | Rationale                   |
| ----------- | --------------------- | --------------------------- |
| Memory      | 4-6 GB                | Query buffer + merge ops    |
| Disk        | 100 GB initial        | ~2 GB/month at 10x compress |
| Engine      | MergeTree             | Standard for analytics      |
| Compression | LZ4 (default) or ZSTD | Balance speed/ratio         |

### OTEL ClickHouse Exporter

Native OTEL Collector exporter for ClickHouse. See [clickhouseexporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/clickhouseexporter).

| Feature      | Status | Notes                        |
| ------------ | ------ | ---------------------------- |
| Logs         | Beta   | Production ready             |
| Traces       | Beta   | If needed for Tempo overflow |
| Metrics      | Alpha  | Long-term metrics storage    |
| Auto-schema  | ✅     | Creates tables automatically |
| TTL          | ✅     | Built into exporter config   |
| Async insert | ✅     | Better throughput            |

**Example config:**

```yaml
exporters:
  clickhouse:
    endpoint: tcp://localhost:9000
    database: otel
    async_insert: true
    ttl: 720h # 30 days
    compress: lz4
    create_schema: true
    logs_table_name: zeek_logs
```

### Grafana ClickHouse Plugin

Official plugin with OTEL integration. See [grafana-clickhouse-datasource](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/).

| Feature        | Description                        |
| -------------- | ---------------------------------- |
| Query builder  | Visual query construction          |
| SQL editor     | Raw SQL for complex queries        |
| OTEL logs view | Native support for OTEL log schema |
| Time series    | Automatic time bucketing           |
| Variables      | Template variables for dashboards  |

## Use Cases

### Zeek Network Analytics

Primary use case — replace Loki for Zeek logs. Queries below use typed columns from MVs.

```sql
-- Top talkers by connection count (24h)
-- Uses: zeek_conn typed table with IPv4 column
SELECT
    id_orig_h AS source_ip,
    count() AS connections,
    sum(orig_bytes) AS bytes_sent
FROM zeek_conn
WHERE Timestamp > now() - INTERVAL 24 HOUR
GROUP BY source_ip
ORDER BY connections DESC
LIMIT 20;

-- Connections by hour for specific IP
-- Uses: native IPv4 comparison (fast)
SELECT
    toStartOfHour(Timestamp) AS hour,
    count() AS connections
FROM zeek_conn
WHERE id_orig_h = toIPv4('10.0.3.10')
  AND Timestamp > now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour;

-- DNS queries by domain (anomaly detection)
-- Uses: zeek_dns typed table
SELECT
    query,
    count() AS queries,
    uniqExact(id_orig_h) AS unique_clients
FROM zeek_dns
WHERE Timestamp > now() - INTERVAL 24 HOUR
GROUP BY query
ORDER BY queries DESC
LIMIT 50;

-- Use pre-aggregated hourly view for dashboards
SELECT
    hour,
    sum(connections) AS total_connections,
    sum(bytes_sent) AS total_bytes
FROM zeek_conn_hourly
WHERE hour > now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour;
```

### Long-Term Metrics Storage

Prometheus remote write to ClickHouse for months/years of history.

```sql
-- CPU usage trend over 90 days
SELECT
    toStartOfDay(Timestamp) AS day,
    avg(Value) AS avg_cpu
FROM otel_metrics
WHERE MetricName = 'system_cpu_usage'
  AND exported_job = 'monitoring-stack'
  AND Timestamp > now() - INTERVAL 90 DAY
GROUP BY day
ORDER BY day;
```

### High-Cardinality Metrics

Metrics that would explode Prometheus cardinality.

```sql
-- Per-container resource usage (all containers, all time)
SELECT
    container_name,
    avg(cpu_percent) AS avg_cpu,
    max(memory_usage) AS peak_memory
FROM container_metrics
WHERE Timestamp > now() - INTERVAL 30 DAY
GROUP BY container_name;

-- Per-IP traffic stats (would kill Prometheus labels)
SELECT
    src_ip,
    dst_ip,
    sum(bytes) AS total_bytes,
    count() AS connections
FROM flow_data
WHERE Timestamp > now() - INTERVAL 7 DAY
GROUP BY src_ip, dst_ip
ORDER BY total_bytes DESC
LIMIT 100;
```

### Future: NetFlow/sFlow

If VyOS NetFlow export is enabled:

```sql
-- Traffic matrix by VLAN
SELECT
    src_vlan,
    dst_vlan,
    sum(bytes) AS bytes,
    count() AS flows
FROM netflow
WHERE Timestamp > now() - INTERVAL 24 HOUR
GROUP BY src_vlan, dst_vlan;
```

## Data Flow

| Source     | Data                    | Destination | Why                               |
| ---------- | ----------------------- | ----------- | --------------------------------- |
| Zeek       | conn, dns, http, ssl... | ClickHouse  | High volume, SQL analytics needed |
| Suricata   | Alerts                  | Loki        | Lower volume, pattern matching    |
| Suricata   | Alert counts            | Prometheus  | Pre-aggregated for dashboards     |
| All VMs    | System metrics          | Prometheus  | Standard observability            |
| All VMs    | Logs                    | Loki        | General log aggregation           |
| Prometheus | Long-term metrics       | ClickHouse  | Historical trending (optional)    |

### Zeek → ClickHouse Pipeline

```
Zeek container → JSON files → OTEL filelog receiver → batch processor → clickhouse exporter → ClickHouse
     │                │                │                      │                  │
     │                │                │                      │                  └── INSERT into tables
     │                │                │                      └── Buffer 10k rows or 5s
     │                │                └── Tail files, parse JSON, extract timestamp
     │                └── /var/lib/zeek/logs/*.log (conn.log, dns.log, etc.)
     └── zeek -i ens19 local LogAscii::use_json=T
```

**Key detail:** Zeek must output JSON logs (not default TSV). Currently configured in `ids-stack.nix` with `LogAscii::use_json=T`.

### Zeek Log Rotation

**Important:** Standalone Zeek (`zeek -i eth0`) does NOT rotate logs by default — they grow until disk fills.

Current IDS stack runs standalone mode. Options:

1. **Zeek-native rotation** (recommended):

   ```
   zeek -i ens19 local LogAscii::use_json=T Log::default_rotation_interval=1hr
   ```

2. **Host-side cleanup** after OTEL ingests:
   ```nix
   systemd.services.zeek-log-cleanup = {
     serviceConfig.ExecStart = "find /var/lib/zeek/logs -name '*.log' -mtime +1 -delete";
   };
   systemd.timers.zeek-log-cleanup = {
     timerConfig.OnCalendar = "hourly";
   };
   ```

Since ClickHouse handles retention via TTL, local logs only need to persist long enough for OTEL to ingest them (minutes to hours).

## Schema Design

### OTEL Default Schema

The OTEL exporter creates tables automatically with a **generic schema**:

```sql
CREATE TABLE otel_logs (
    Timestamp DateTime64(9),
    TraceId String,
    SpanId String,
    TraceFlags UInt32,
    SeverityText LowCardinality(String),
    SeverityNumber Int32,
    ServiceName LowCardinality(String),
    Body String,
    ResourceAttributes Map(LowCardinality(String), String),
    LogAttributes Map(LowCardinality(String), String)  -- All Zeek fields end up here
) ENGINE = MergeTree()
ORDER BY (ServiceName, Timestamp)
TTL Timestamp + INTERVAL 30 DAY;
```

**With default schema, queries use Map access:**

```sql
-- Works but slower — Map lookup + type cast on every row
SELECT
    LogAttributes['id.orig_h'] AS source_ip,
    toUInt64OrZero(LogAttributes['orig_bytes']) AS bytes_sent
FROM otel_logs
WHERE LogAttributes['_path'] = 'conn'
  AND Timestamp > now() - INTERVAL 24 HOUR;
```

### Typed Tables via Materialized Views (Recommended)

For analytics performance, use MVs to transform OTEL's generic schema into typed columns.

**Pattern:** OTEL inserts into Null table → MV transforms → Typed table stored

```sql
-- 1. Ingest table (Null engine = accepts inserts but stores nothing)
CREATE TABLE zeek_ingest (
    Timestamp DateTime64(9),
    Body String,
    LogAttributes Map(LowCardinality(String), String)
) ENGINE = Null;

-- 2. Typed destination table (actually stored)
CREATE TABLE zeek_conn (
    Timestamp DateTime64(9),
    uid String,
    id_orig_h IPv4,
    id_orig_p UInt16,
    id_resp_h IPv4,
    id_resp_p UInt16,
    proto LowCardinality(String),
    service LowCardinality(String),
    duration Float64,
    orig_bytes UInt64,
    resp_bytes UInt64,
    conn_state LowCardinality(String),
    history String,
    orig_pkts UInt64,
    resp_pkts UInt64
) ENGINE = MergeTree()
ORDER BY (Timestamp, id_orig_h)
TTL Timestamp + INTERVAL 14 DAY;

-- 3. MV transforms on insert (synchronous — no lag)
CREATE MATERIALIZED VIEW zeek_conn_mv TO zeek_conn AS
SELECT
    Timestamp,
    LogAttributes['uid'] AS uid,
    toIPv4OrDefault(LogAttributes['id.orig_h']) AS id_orig_h,
    toUInt16OrZero(LogAttributes['id.orig_p']) AS id_orig_p,
    toIPv4OrDefault(LogAttributes['id.resp_h']) AS id_resp_h,
    toUInt16OrZero(LogAttributes['id.resp_p']) AS id_resp_p,
    LogAttributes['proto'] AS proto,
    LogAttributes['service'] AS service,
    toFloat64OrZero(LogAttributes['duration']) AS duration,
    toUInt64OrZero(LogAttributes['orig_bytes']) AS orig_bytes,
    toUInt64OrZero(LogAttributes['resp_bytes']) AS resp_bytes,
    LogAttributes['conn_state'] AS conn_state,
    LogAttributes['history'] AS history,
    toUInt64OrZero(LogAttributes['orig_pkts']) AS orig_pkts,
    toUInt64OrZero(LogAttributes['resp_pkts']) AS resp_pkts
FROM zeek_ingest
WHERE LogAttributes['_path'] = 'conn';
```

**Now queries use native typed columns:**

```sql
-- Fast — native IPv4 comparison, integer aggregation
SELECT
    id_orig_h AS source_ip,
    sum(orig_bytes) AS bytes_sent
FROM zeek_conn
WHERE id_orig_h = toIPv4('10.0.3.5')
  AND Timestamp > now() - INTERVAL 24 HOUR
GROUP BY source_ip;
```

### Why Null + MV?

| Approach                     | Storage | Query Speed | Notes                                      |
| ---------------------------- | ------- | ----------- | ------------------------------------------ |
| OTEL default only            | 1x      | Slow        | Map access + casts every query             |
| OTEL + typed table (no Null) | 2x      | Fast        | Duplicate storage                          |
| Null + MV → typed            | 1x      | Fast        | **Best** — transform at insert, store once |

The MV transformation is **synchronous** — data appears in typed table immediately after INSERT completes.

### Additional Typed Tables

```sql
-- DNS logs
CREATE TABLE zeek_dns (
    Timestamp DateTime64(9),
    uid String,
    id_orig_h IPv4,
    id_resp_h IPv4,
    query String,
    qtype_name LowCardinality(String),
    rcode_name LowCardinality(String),
    answers Array(String)
) ENGINE = MergeTree()
ORDER BY (Timestamp, query)
TTL Timestamp + INTERVAL 30 DAY;

CREATE MATERIALIZED VIEW zeek_dns_mv TO zeek_dns AS
SELECT
    Timestamp,
    LogAttributes['uid'] AS uid,
    toIPv4OrDefault(LogAttributes['id.orig_h']) AS id_orig_h,
    toIPv4OrDefault(LogAttributes['id.resp_h']) AS id_resp_h,
    LogAttributes['query'] AS query,
    LogAttributes['qtype_name'] AS qtype_name,
    LogAttributes['rcode_name'] AS rcode_name,
    splitByChar(',', LogAttributes['answers']) AS answers
FROM zeek_ingest
WHERE LogAttributes['_path'] = 'dns';
```

### Aggregation Views (Pre-computed)

```sql
-- Hourly connection aggregates per IP
CREATE MATERIALIZED VIEW zeek_conn_hourly
ENGINE = SummingMergeTree()
ORDER BY (hour, id_orig_h)
AS SELECT
    toStartOfHour(Timestamp) AS hour,
    id_orig_h,
    count() AS connections,
    sum(orig_bytes) AS bytes_sent,
    sum(resp_bytes) AS bytes_received
FROM zeek_conn
GROUP BY hour, id_orig_h;
```

## Retention Strategy

Tiered retention — keep bulk data shorter, extend valuable investigation data.

| Table            | Volume | Retention | Storage Est.   | Rationale                    |
| ---------------- | ------ | --------- | -------------- | ---------------------------- |
| zeek_conn        | ~70%   | 30 days   | ~30-45 GB      | Bulk data, most is noise     |
| zeek_dns         | ~15%   | 90 days   | ~15-20 GB      | Investigation gold           |
| zeek_http        | ~10%   | 60 days   | ~8-12 GB       | Moderate value               |
| zeek_ssl         | ~3%    | 90 days   | ~3-5 GB        | Certificate tracking         |
| zeek_notice      | ~2%    | 180 days  | ~2-3 GB        | Alerts, highest value        |
| otel_metrics     | —      | 365 days  | ~20 GB         | Long-term trending           |
| Aggregated views | —      | 365 days  | ~1-2 GB        | Pre-computed, tiny footprint |
| **Total**        |        |           | **~80-110 GB** |                              |

**256 GB disk budget with ~110 GB ClickHouse = plenty of headroom.**

**TTL configuration:**

```sql
-- Per-table TTL based on value vs volume
ALTER TABLE zeek_conn MODIFY TTL Timestamp + INTERVAL 30 DAY;
ALTER TABLE zeek_dns MODIFY TTL Timestamp + INTERVAL 90 DAY;
ALTER TABLE zeek_http MODIFY TTL Timestamp + INTERVAL 60 DAY;
ALTER TABLE zeek_ssl MODIFY TTL Timestamp + INTERVAL 90 DAY;
ALTER TABLE zeek_notice MODIFY TTL Timestamp + INTERVAL 180 DAY;

-- Aggregated views keep 1 year (tiny footprint)
ALTER TABLE zeek_conn_hourly MODIFY TTL hour + INTERVAL 365 DAY;
```

## Integration with Existing Stack

### IDS Stack → ClickHouse (Complete Config)

```yaml
# ids-stack OTEL Collector config

receivers:
  # Tail Zeek JSON logs
  filelog/zeek:
    include:
      - /var/lib/zeek/logs/*.log
      - /var/lib/zeek/logs/**/*.log # rotated logs
    exclude:
      - /var/lib/zeek/logs/stats.log # noisy, skip
    start_at: end
    include_file_name: true
    operators:
      # Parse Zeek JSON
      - type: json_parser
        timestamp:
          parse_from: attributes.ts
          layout_type: epoch
          layout: seconds
      # Extract log type from filename (conn.log → conn)
      - type: regex_parser
        regex: '.*/(?P<_path>[^/]+)\.log$'
        parse_from: attributes["log.file.name"]
        parse_to: attributes

processors:
  batch:
    send_batch_size: 10000
    timeout: 5s

exporters:
  clickhouse:
    endpoint: tcp://{{ monitoring_stack_ip }}:9000
    database: otel
    async_insert: true
    ttl: 336h # 14 days
    compress: lz4
    create_schema: false # We manage schema (Null + MVs)
    logs_table_name: zeek_ingest # Null engine table

service:
  pipelines:
    logs/zeek:
      receivers: [filelog/zeek]
      processors: [batch]
      exporters: [clickhouse]
```

**Key points:**

- `create_schema: false` — we manage the Null table + MVs manually
- `logs_table_name: zeek_ingest` — points to Null engine table
- MVs transform and route to typed tables (`zeek_conn`, `zeek_dns`, etc.)

### Router → Loki + Prometheus

Keep Suricata in Loki (lower volume, alert-focused) with metric aggregation:

```yaml
# otel-collector-config.yml.j2
connectors:
  count:
    logs:
      suricata_alerts_total:
        description: "Suricata alert count by severity"
        conditions:
          - 'attributes["event_type"] == "alert"'
        attributes:
          - key: severity

pipelines:
  logs/suricata:
    receivers: [filelog/suricata]
    processors: [batch]
    exporters: [loki]

  metrics/suricata:
    receivers: [count]
    exporters: [prometheus]
```

### Grafana Datasources

```yaml
# grafana/provisioning/datasources/clickhouse.yml
apiVersion: 1
datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    url: http://localhost:8123
    jsonData:
      defaultDatabase: otel
      protocol: http
```

## Deployment Plan

### Phase 1: ClickHouse Container

1. Add ClickHouse to monitoring stack Ansible playbook
2. Configure Podman Quadlet with resource limits
3. Provision Grafana ClickHouse datasource
4. Verify connectivity

### Phase 2: Schema Setup

1. Create database: `CREATE DATABASE otel`
2. Create Null ingest table: `zeek_ingest` (ENGINE = Null)
3. Create typed tables: `zeek_conn`, `zeek_dns`, `zeek_http`, `zeek_ssl`
4. Create MVs to transform and route from ingest → typed tables
5. Create aggregation views (hourly rollups)
6. Verify schema with test INSERTs

### Phase 3: Zeek → ClickHouse

1. Configure Zeek log rotation in `ids-stack.nix`:
   - Add `Log::default_rotation_interval=1hr` to Zeek command
   - Or add systemd timer to clean up old logs
2. Update IDS Stack OTEL config:
   - Add `filelog/zeek` receiver with JSON parser
   - Add `clickhouse` exporter pointing to `zeek_ingest`
3. Deploy and test log ingestion
4. Verify data appears in typed tables via MVs
5. Create Zeek dashboards in Grafana
6. Verify TTL cleanup working
7. Remove Zeek logs from Loki pipeline (stop dual-write)

### Phase 3: Suricata Metrics

1. Add count connector to router OTEL config
2. Create Suricata metrics dashboard panels
3. Update alerts to use Prometheus metrics
4. Keep raw Suricata logs in Loki for search

### Phase 4: Long-Term Metrics (Optional)

1. Configure Prometheus remote write to ClickHouse
2. Create long-term trending dashboards
3. Reduce Prometheus retention (offload to ClickHouse)

## Resource Requirements

### Monitoring Stack Changes

```yaml
monitoring_stack:
  memory: 16384 # 8GB → 16GB
  disk_gb: 256 # 128GB → 256GB
  # cores: 4        # Keep as-is
```

**Memory breakdown:**

| Component  | Current  | After ClickHouse    |
| ---------- | -------- | ------------------- |
| Prometheus | ~2 GB    | ~2 GB               |
| Loki       | ~2 GB    | ~1.5 GB (less Zeek) |
| Grafana    | ~1 GB    | ~1 GB               |
| OTEL       | ~500 MB  | ~500 MB             |
| Tempo      | ~500 MB  | ~500 MB             |
| ClickHouse | —        | ~4-6 GB             |
| Headroom   | ~2 GB    | ~4-5 GB             |
| **Total**  | **8 GB** | **~16 GB**          |

**Disk breakdown:**

| Data                 | Current     | After ClickHouse        |
| -------------------- | ----------- | ----------------------- |
| Prometheus           | ~20 GB      | ~20 GB                  |
| Loki                 | ~60 GB      | ~30 GB (no Zeek)        |
| ClickHouse (Zeek)    | —           | ~80-110 GB (tiered TTL) |
| ClickHouse (metrics) | —           | ~20 GB (1y)             |
| Grafana/Other        | ~10 GB      | ~10 GB                  |
| **Used**             | **~90 GB**  | **~160-190 GB**         |
| **Headroom**         | **~166 GB** | **~66-96 GB**           |

### Host Capacity (Niobe)

| Resource | Total  | Before | After       | Free      |
| -------- | ------ | ------ | ----------- | --------- |
| RAM      | 64 GB  | 14 GB  | 22 GB       | 42 GB     |
| Disk     | 512 GB | ~90 GB | ~160-190 GB | ~66-96 GB |

Plenty of headroom for 90-day retention on valuable logs.

## Maintenance

| Task              | Frequency | Method                       |
| ----------------- | --------- | ---------------------------- |
| TTL cleanup       | Automatic | ClickHouse background merges |
| Disk monitoring   | Daily     | Grafana alerts               |
| Query performance | Weekly    | system.query_log analysis    |
| Schema updates    | As needed | Migration scripts            |
| Backup            | Daily     | PBS VM backup (includes CH)  |

**Backup note:** Dedicated `clickhouse-backup` tool is overkill for homelab. PBS already backs up the monitoring stack VM including ClickHouse data directory. If needed, native `BACKUP TABLE ... TO Disk(...)` command provides table-level granularity. Since this is analytics/log data with TTL, losing some history on restore is acceptable.

### Monitoring ClickHouse

```sql
-- Check table sizes
SELECT
    table,
    formatReadableSize(sum(bytes)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE active
GROUP BY table
ORDER BY sum(bytes) DESC;

-- Slow queries
SELECT
    query,
    query_duration_ms,
    read_rows,
    memory_usage
FROM system.query_log
WHERE query_duration_ms > 1000
ORDER BY event_time DESC
LIMIT 20;
```

## Decision Factors

### Pros

- 10-20x better compression than Loki for structured logs
- SQL queries orders of magnitude faster for analytics
- Native OTEL integration (beta, production ready)
- Official Grafana plugin with good UX
- Per-IP analytics finally feasible
- Long-term metrics storage without Prometheus scaling issues
- TTL/retention per-table, very flexible
- Single binary, easy to operate

### Cons

- Another service to maintain
- Memory hungry (4-6 GB minimum for good performance)
- Learning curve for ClickHouse SQL dialect
- OTEL exporter is beta (but stable)
- Need to manage two log stores (ClickHouse + Loki)

### When to Use ClickHouse

| Use Case                          | ClickHouse | Loki |
| --------------------------------- | ---------- | ---- |
| High-volume structured logs       | ✅         | ❌   |
| SQL analytics / aggregations      | ✅         | ❌   |
| Per-IP / high-cardinality queries | ✅         | ❌   |
| Long-term metrics retention       | ✅         | ❌   |
| Pattern matching / grep           | ⚠️         | ✅   |
| Unstructured logs                 | ❌         | ✅   |
| Low-volume alert logs             | ❌         | ✅   |
| Quick setup / minimal ops         | ❌         | ✅   |

## Alternatives Considered

### Keep Everything in Loki

| Pros                 | Cons                                   |
| -------------------- | -------------------------------------- |
| Single log store     | Query performance degrades with volume |
| Already deployed     | No SQL, LogQL has limits               |
| Lower resource usage | High cardinality not feasible          |

**Verdict:** Doesn't scale for Zeek analytics workload.

### Elasticsearch

| Pros             | Cons                                |
| ---------------- | ----------------------------------- |
| Full-text search | 3-5x more resources than ClickHouse |
| Mature ecosystem | Complex to operate (JVM tuning)     |
| Kibana built-in  | Overkill — don't need FTS for Zeek  |
| Detection rules  | Would require Kibana (another UI)   |

**Verdict:** Better for SIEM use case. ClickHouse wins for structured analytics.

### VictoriaMetrics

| Pros                  | Cons                           |
| --------------------- | ------------------------------ |
| Great for metrics     | Not designed for logs          |
| Prometheus compatible | Would still need Loki for logs |
| Lower resource usage  | Doesn't solve Zeek problem     |

**Verdict:** Good for metrics-only, doesn't address log analytics.

### TimescaleDB

| Pros                  | Cons                                 |
| --------------------- | ------------------------------------ |
| PostgreSQL compatible | Slower than ClickHouse for analytics |
| SQL familiarity       | Higher resource usage                |
| Good compression      | No native OTEL exporter              |

**Verdict:** ClickHouse purpose-built for this workload.

## Open Questions

1. ~~**Custom Zeek tables vs OTEL default?**~~ **Resolved:** Use Null table + MVs for typed columns. Best of both worlds — OTEL compatibility with native type performance.
2. **Prometheus remote write?** Phase 4 — evaluate after Zeek migration
3. ~~**Backup strategy?**~~ **Resolved:** PBS VM backup is sufficient. clickhouse-backup overkill for homelab.
4. **Clustering?** Single node sufficient for homelab scale
5. **ZSTD vs LZ4?** Start with LZ4 (faster), switch to ZSTD if disk constrained
6. ~~**How does data get into typed tables?**~~ **Resolved:** MVs transform synchronously on INSERT. Null engine avoids double storage.

## Status

**Implemented.** ClickHouse deployed to monitoring stack.

**What was done:**

1. ✅ Monitoring stack already at 16GB RAM, 256GB disk
2. ✅ ClickHouse container added to monitoring-stack pod (`ansible/playbooks/monitoring_stack/site.yml`)
3. ✅ SQL init scripts created for typed tables + MVs (`ansible/playbooks/monitoring_stack/clickhouse/`)
4. ✅ Zeek log rotation added to `nix/hosts/oracle/ids-stack.nix`
5. ✅ OTEL config updated to route Zeek logs to ClickHouse (`otel_config.yml`)
6. ✅ IDS dashboard updated with ClickHouse panels for Zeek analytics

**Deployment:**

```bash
# Deploy home gateway (adds clickhouse.home.shdr.ch)
task deploy:home-gateway-stack

# Deploy monitoring stack with ClickHouse
# SQL init scripts run automatically on first startup
task deploy:monitoring-stack

# Deploy IDS stack with log rotation
task configure:ids-stack
```

**Schema auto-init:** The `otel_logs` table is pre-created with OTEL's exact schema (from [logs_table.sql](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/clickhouseexporter/internal/sqltemplates/logs_table.sql)), so MVs and typed tables are created at container startup. No manual SQL execution needed.

**Play UI:** Available at `https://clickhouse.home.shdr.ch/play` for ad-hoc queries.

## Related Documents

- `network-security.md` — IDS Stack (Suricata + Zeek) generates the logs
- `osquery.md` — Fleet also benefits from ClickHouse for query results
- `../monitoring.md` — Existing observability stack
- `../virtual-machines.md` — VM resource allocation
