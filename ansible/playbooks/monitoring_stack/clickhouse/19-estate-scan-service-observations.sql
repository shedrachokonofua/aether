-- Preserve one service observation per scan run.
-- Migration 003_service_observations; immutable after first application.

CREATE TABLE IF NOT EXISTS estate_scan.service_observations
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
PARTITION BY toYYYYMM(last_seen_at)
ORDER BY (run_id, asset_id, transport, port, service_id)
TTL toDateTime(last_seen_at) + INTERVAL 730 DAY;

INSERT INTO estate_scan.service_observations
SELECT *
FROM estate_scan.services FINAL
WHERE NOT EXISTS
(
    SELECT 1
    FROM estate_scan.service_observations
    LIMIT 1
);

