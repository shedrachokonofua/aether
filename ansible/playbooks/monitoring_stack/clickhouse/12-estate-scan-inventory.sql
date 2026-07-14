-- Estate-scan hostname inventory observations (Phase 2 automated inventory).
-- Idempotent DDL; applied after 11-estate-scan-schema.sql.

CREATE TABLE IF NOT EXISTS estate_scan.inventory_observations
(
    observed_at DateTime64(3, 'UTC'),
    inventory_revision String,
    source LowCardinality(String),
    declared_count UInt64,
    ct_count UInt64,
    scannable_count UInt64,
    ct_only_count UInt64,
    ct_status LowCardinality(String),
    payload String,
    version UInt64
)
ENGINE = MergeTree
ORDER BY observed_at
TTL toDateTime(observed_at) + INTERVAL 730 DAY;

CREATE TABLE IF NOT EXISTS estate_scan.inventory_names
(
    name String,
    declared UInt8,
    l7_scan_enabled UInt8,
    provenance LowCardinality(String),
    ipv4 Nullable(IPv4),
    url String,
    exposure LowCardinality(String),
    inventory_revision String,
    observed_at DateTime64(3, 'UTC'),
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY name
TTL toDateTime(observed_at) + INTERVAL 730 DAY;
