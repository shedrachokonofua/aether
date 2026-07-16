-- All-time first-seen registry per MAC, maintained by MV from
-- network.observations (MV chaining off the ingest MVs is standard CH
-- behavior). Query with GROUP BY mac: AggregatingMergeTree parts merge lazily.
CREATE TABLE IF NOT EXISTS network.mac_first_seen (
    mac String,
    first_seen SimpleAggregateFunction(min, DateTime64(3)),
    last_seen SimpleAggregateFunction(max, DateTime64(3)),
    hostname SimpleAggregateFunction(anyLast, Nullable(String))
) ENGINE = AggregatingMergeTree
ORDER BY mac;

CREATE MATERIALIZED VIEW IF NOT EXISTS network.mac_first_seen_mv
TO network.mac_first_seen AS
SELECT
    lower(mac_address) AS mac,
    min(timestamp) AS first_seen,
    max(timestamp) AS last_seen,
    anyLast(hostname) AS hostname
FROM network.observations
WHERE mac_address IS NOT NULL AND mac_address != ''
  -- exclude multicast MACs (odd second nibble): switch FDB can carry
  -- multicast group entries that are not devices
  AND lower(substring(mac_address, 2, 1)) NOT IN ('1', '3', '5', '7', '9', 'b', 'd', 'f')
GROUP BY mac;
