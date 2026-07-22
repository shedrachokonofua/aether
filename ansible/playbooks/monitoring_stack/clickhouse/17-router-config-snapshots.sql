-- Router config snapshots (drift detection) — dedicated router_drift channel.
--
-- The router periodically dumps `show configuration commands`, REDACTS secret
-- lines at source, and writes one NDJSON record into its OWN observations dir
-- (/config/router-drift/observations), tagged log.source=router_drift by a
-- dedicated filelog receiver. This is deliberately SEPARATE from the
-- vyos-exporter's vyos_observations stream, whose contract (REQUIREMENTS.md
-- 339/527) forbids config content: this drift channel is the explicit,
-- opt-in place where redacted config content is allowed to travel.
--
-- Keyed on sha256 so an unchanged config collapses to one row (idempotent
-- replay) while each real change is a new row -> drift history (90d TTL). The
-- comparator reads the latest row per host and diffs against the repo.
--
-- Fail-closed: if the on-router redactor cannot verify a line is clean, it
-- emits kind=router_config_snapshot_redaction_failed with config='' and the
-- MV records status='redaction_failed' (hash only) so the failure is VISIBLE
-- to the comparator/alerts rather than silently dropped.

DROP VIEW IF EXISTS network.router_config_snapshots_mv;
DROP TABLE IF EXISTS network.router_config_snapshots;

CREATE TABLE network.router_config_snapshots (
    timestamp DateTime64(3),
    ingested_at DateTime64(3) DEFAULT now64(3),
    source_instance LowCardinality(String),
    status LowCardinality(String),
    sha256 String,
    line_count UInt32,
    config String
) ENGINE = ReplacingMergeTree(ingested_at)
ORDER BY (source_instance, sha256)
TTL toDateTime(timestamp) + INTERVAL 90 DAY;

CREATE MATERIALIZED VIEW network.router_config_snapshots_mv
TO network.router_config_snapshots AS
SELECT
    parseDateTime64BestEffortOrNull(JSONExtractString(Body, 'timestamp'), 3) AS timestamp,
    JSONExtractString(Body, 'source_instance') AS source_instance,
    if(JSONExtractString(Body, 'kind') = 'router_config_snapshot_redaction_failed',
       'redaction_failed', 'ok') AS status,
    JSONExtractString(Body, 'sha256') AS sha256,
    toUInt32(JSONExtractUInt(Body, 'line_count')) AS line_count,
    JSONExtractString(Body, 'config') AS config
FROM network.ingest
WHERE LogAttributes['log.source'] = 'router_drift'
  AND JSONExtractString(Body, 'kind') IN
      ('router_config_snapshot', 'router_config_snapshot_redaction_failed');
