-- qss-exporter observations: same schema v1 / sealed-NDJSON contract as vyos
-- (see qss-exporter docs/observations.md). Second MV into the shared
-- network.observations table; ReplacingMergeTree on observation_id keeps
-- replays idempotent.
CREATE MATERIALIZED VIEW IF NOT EXISTS network.observations_qss_mv
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
WHERE LogAttributes['log.source'] = 'qss_observations'
  AND JSONExtractString(Body, 'kind') != 'snapshot_complete'
  AND JSONExtractString(Body, 'observation_id') != '';
