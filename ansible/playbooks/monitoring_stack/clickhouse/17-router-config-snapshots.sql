-- Router config snapshots (drift detection).
--
-- The router periodically dumps `show configuration commands`, REDACTS secret
-- lines at source, and drops one NDJSON record into its vyos-exporter
-- observations dir. That rides the existing filelog -> OTel -> network.ingest
-- path (log.source=vyos_observations), and this MV routes the config-snapshot
-- records into a dedicated table. Keyed on sha256 so an unchanged config
-- collapses to one row (idempotent replay) while each real change is a new
-- row -> queryable drift history. The comparator reads the latest row per
-- host and diffs against the repo's declared config; secrets never leave the
-- router, so this table only ever holds redacted `<redacted>` placeholders.
--
-- Coexists with 09-vyos-observations: that MV requires observation_id != '',
-- which these records deliberately omit, so they never cross-pollute.

CREATE TABLE IF NOT EXISTS network.router_config_snapshots (
    timestamp DateTime64(3),
    ingested_at DateTime64(3) DEFAULT now64(3),
    source_instance LowCardinality(String),
    sha256 String,
    line_count UInt32,
    config String
) ENGINE = ReplacingMergeTree(ingested_at)
ORDER BY (source_instance, sha256)
TTL toDateTime(timestamp) + INTERVAL 90 DAY;

CREATE MATERIALIZED VIEW IF NOT EXISTS network.router_config_snapshots_mv
TO network.router_config_snapshots AS
SELECT
    parseDateTime64BestEffortOrNull(JSONExtractString(Body, 'timestamp'), 3) AS timestamp,
    JSONExtractString(Body, 'source_instance') AS source_instance,
    JSONExtractString(Body, 'sha256') AS sha256,
    toUInt32(JSONExtractUInt(Body, 'line_count')) AS line_count,
    JSONExtractString(Body, 'config') AS config
FROM network.ingest
WHERE LogAttributes['log.source'] = 'vyos_observations'
  AND JSONExtractString(Body, 'kind') = 'router_config_snapshot';
