-- VyOS exporter observations.
--
-- The OpenTelemetry ClickHouse exporter writes its fixed log schema to the
-- Null-engine ingest table. This materialized view parses each sealed-NDJSON
-- body into a ReplacingMergeTree keyed by deterministic observation_id, so
-- replaying an already delivered file remains idempotent under FINAL.
CREATE DATABASE IF NOT EXISTS network;

CREATE TABLE IF NOT EXISTS network.ingest (
    Timestamp DateTime64(9),
    TimestampTime DateTime DEFAULT toDateTime(Timestamp),
    TraceId String,
    SpanId String,
    TraceFlags UInt8,
    SeverityText LowCardinality(String),
    SeverityNumber UInt8,
    ServiceName LowCardinality(String),
    Body String,
    ResourceSchemaUrl LowCardinality(String),
    ResourceAttributes Map(LowCardinality(String), String),
    ScopeSchemaUrl LowCardinality(String),
    ScopeName String,
    ScopeVersion LowCardinality(String),
    ScopeAttributes Map(LowCardinality(String), String),
    LogAttributes Map(LowCardinality(String), String),
    EventName String
) ENGINE = Null;

CREATE TABLE IF NOT EXISTS network.observations (
    timestamp DateTime64(3),
    ingested_at DateTime64(3) DEFAULT now64(3),
    schema_version UInt32,
    observation_id String,
    snapshot_id String,
    source_instance String,
    source_type LowCardinality(String),
    kind LowCardinality(String),
    event LowCardinality(Nullable(String)),
    ip_address Nullable(String),
    mac_address Nullable(String),
    hostname Nullable(String),
    interface LowCardinality(Nullable(String)),
    network_segment LowCardinality(Nullable(String)),
    pool LowCardinality(Nullable(String)),
    state LowCardinality(Nullable(String)),
    valid_from DateTime64(3),
    valid_until Nullable(DateTime64(3)),
    confidence LowCardinality(String),
    attributes String
) ENGINE = ReplacingMergeTree(ingested_at)
ORDER BY (source_type, observation_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS network.observations_mv
TO network.observations AS
SELECT
    parseDateTime64BestEffortOrNull(JSONExtractString(Body, 'timestamp'), 3) AS timestamp,
    toUInt32(JSONExtractUInt(Body, 'schema_version')) AS schema_version,
    JSONExtractString(Body, 'observation_id') AS observation_id,
    JSONExtractString(Body, 'snapshot_id') AS snapshot_id,
    JSONExtractString(Body, 'source_instance') AS source_instance,
    JSONExtractString(Body, 'source_type') AS source_type,
    JSONExtractString(Body, 'kind') AS kind,
    nullIf(JSONExtractString(Body, 'event'), '') AS event,
    nullIf(JSONExtractString(Body, 'ip_address'), '') AS ip_address,
    nullIf(JSONExtractString(Body, 'mac_address'), '') AS mac_address,
    nullIf(JSONExtractString(Body, 'hostname'), '') AS hostname,
    nullIf(JSONExtractString(Body, 'interface'), '') AS interface,
    nullIf(JSONExtractString(Body, 'network_segment'), '') AS network_segment,
    nullIf(JSONExtractString(Body, 'pool'), '') AS pool,
    nullIf(JSONExtractString(Body, 'state'), '') AS state,
    parseDateTime64BestEffortOrNull(JSONExtractString(Body, 'valid_from'), 3) AS valid_from,
    parseDateTime64BestEffortOrNull(JSONExtractString(Body, 'valid_until'), 3) AS valid_until,
    JSONExtractString(Body, 'confidence') AS confidence,
    JSONExtractRaw(Body, 'attributes') AS attributes
FROM network.ingest
WHERE LogAttributes['log.source'] = 'vyos_observations'
  AND JSONExtractString(Body, 'kind') != 'snapshot_complete'
  AND JSONExtractString(Body, 'observation_id') != '';
