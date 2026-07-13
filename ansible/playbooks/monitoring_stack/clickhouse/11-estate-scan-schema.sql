-- Estate discovery and vulnerability scan state.
-- Source of truth for Phase 0 of docs/exploration/estate-scanning.md.
-- Idempotent DDL; applied by the monitoring_stack estate-scan tag.
-- Do not create users or grants here (Grafana SELECT via site.yml; writer identity in Phase 2).
--
-- Scan-aware IDS handling (no blanket scanner-IP exclusion):
--   * Scanner source identity once live: config/vm.yml estate_scanner.ip (10.0.2.13).
--   * Expected closed/timeout authorized probes are recorded in estate_scan.probe_aggregates
--     (and later derived from Zeek/Suricata by run/network/state), not one-for-one in
--     general zeek.conn / suricata flow tables.
--   * Successful handshakes, application exchanges, unexpected responses, unauthorized
--     destinations, and off-schedule scanner traffic remain in Zeek/Suricata evidence.
--   * OTEL filter / MV implementation lands when the guest emits traffic (Phase 1–2).
--   * Same-L2 VLAN 2 probes may not traverse VyOS eth1 mirror; do not treat the mirror
--     as proof of every estate probe.

CREATE DATABASE IF NOT EXISTS estate_scan;

CREATE TABLE IF NOT EXISTS estate_scan.schema_migrations
(
    migration_id String,
    checksum FixedString(64),
    applied_at DateTime64(3, 'UTC'),
    milestone LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY migration_id;

CREATE TABLE IF NOT EXISTS estate_scan.scan_runs
(
    run_id UUID,
    profile LowCardinality(String),
    vantage LowCardinality(String),
    scanner_revision String,
    nuclei_templates_revision String,
    status Enum8(
        'accepted' = 1,
        'running' = 2,
        'succeeded' = 3,
        'failed' = 4,
        'incomplete' = 5,
        'cancelled' = 6
    ),
    started_at DateTime64(3, 'UTC'),
    finished_at Nullable(DateTime64(3, 'UTC')),
    target_count UInt64,
    probe_count UInt64,
    error_count UInt64,
    timeout_count UInt64,
    dropped_target_count UInt64,
    coverage_ratio Float32,
    error_code LowCardinality(String),
    error_message String,
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(started_at)
ORDER BY run_id
TTL toDateTime(started_at) + INTERVAL 730 DAY;

CREATE TABLE IF NOT EXISTS estate_scan.assets
(
    asset_id FixedString(64),
    stable_identity String,
    ipv4 Nullable(IPv4),
    ipv6 Nullable(IPv6),
    dns_names Array(String),
    mac_address Nullable(String),
    cloud_identity LowCardinality(String),
    kubernetes_identity LowCardinality(String),
    tailscale_identity LowCardinality(String),
    declared UInt8,
    provenance LowCardinality(String),
    owning_source_file String,
    first_seen_at DateTime64(3, 'UTC'),
    last_seen_at DateTime64(3, 'UTC'),
    vantage_points Array(LowCardinality(String)),
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY asset_id
TTL toDateTime(last_seen_at) + INTERVAL 730 DAY;

CREATE TABLE IF NOT EXISTS estate_scan.services
(
    service_id FixedString(64),
    asset_id FixedString(64),
    run_id UUID,
    transport LowCardinality(String),
    port UInt16,
    protocol LowCardinality(String),
    product String,
    product_evidence String,
    http_url String,
    tls_identity String,
    declared UInt8,
    unexpected UInt8,
    confidence Float32,
    first_seen_at DateTime64(3, 'UTC'),
    last_seen_at DateTime64(3, 'UTC'),
    resolved_at Nullable(DateTime64(3, 'UTC')),
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (asset_id, transport, port, service_id)
TTL toDateTime(last_seen_at) + INTERVAL 730 DAY;

CREATE TABLE IF NOT EXISTS estate_scan.findings
(
    finding_key FixedString(64),
    run_id UUID,
    asset_id FixedString(64),
    service_id FixedString(64),
    template_id LowCardinality(String),
    matcher LowCardinality(String),
    severity Enum8(
        'info' = 1,
        'low' = 2,
        'medium' = 3,
        'high' = 4,
        'critical' = 5
    ),
    evidence String,
    first_seen_at DateTime64(3, 'UTC'),
    last_seen_at DateTime64(3, 'UTC'),
    state Enum8(
        'open' = 1,
        'resolved' = 2,
        'suppressed' = 3,
        'review' = 4
    ),
    resolved_at Nullable(DateTime64(3, 'UTC')),
    scanner_revision String,
    nuclei_templates_revision String,
    exposure LowCardinality(String),
    owner String,
    suppression_reason String,
    review_status LowCardinality(String),
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (finding_key, run_id)
TTL toDateTime(last_seen_at) + INTERVAL 730 DAY;

CREATE TABLE IF NOT EXISTS estate_scan.stage_artifacts
(
    run_id UUID,
    stage LowCardinality(String),
    target_group LowCardinality(String),
    artifact_ref String,
    status Enum8(
        'pending' = 1,
        'running' = 2,
        'succeeded' = 3,
        'failed' = 4,
        'skipped' = 5
    ),
    started_at DateTime64(3, 'UTC'),
    finished_at Nullable(DateTime64(3, 'UTC')),
    error_code LowCardinality(String),
    error_message String,
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (run_id, stage, target_group)
TTL toDateTime(started_at) + INTERVAL 730 DAY;

-- Aggregated failed authorized probes for the scanner identity.
-- Authoritative closed/timeout noise lives here; do not duplicate into zeek.conn.
CREATE TABLE IF NOT EXISTS estate_scan.probe_aggregates
(
    run_id UUID,
    window_start DateTime64(3, 'UTC'),
    window_end DateTime64(3, 'UTC'),
    source_ipv4 IPv4,
    network_cidr LowCardinality(String),
    transport LowCardinality(String),
    dest_port UInt16,
    conn_state LowCardinality(String),
    probe_count UInt64,
    version UInt64
)
ENGINE = SummingMergeTree(probe_count)
PARTITION BY toYYYYMM(window_start)
ORDER BY (run_id, window_start, source_ipv4, network_cidr, transport, dest_port, conn_state)
TTL toDateTime(window_start) + INTERVAL 365 DAY;
