-- Historical MAC-to-IP associations from all network observations.
-- A device may have multiple IPs over time, and an IP may be reassigned;
-- retain one aggregate row per MAC, IP, and source type.
CREATE TABLE IF NOT EXISTS network.mac_ip_history (
    mac String,
    ip String,
    first_seen SimpleAggregateFunction(min, DateTime64(3)),
    last_seen SimpleAggregateFunction(max, DateTime64(3)),
    hostname SimpleAggregateFunction(anyLast, Nullable(String)),
    source_type LowCardinality(String)
) ENGINE = AggregatingMergeTree
ORDER BY (mac, ip, source_type);

CREATE MATERIALIZED VIEW IF NOT EXISTS network.mac_ip_history_mv
TO network.mac_ip_history AS
SELECT
    lower(mac_address) AS mac,
    lower(ip_address) AS ip,
    min(timestamp) AS first_seen,
    max(timestamp) AS last_seen,
    anyLast(hostname) AS hostname,
    source_type
FROM network.observations
WHERE mac_address IS NOT NULL AND mac_address != ''
  AND ip_address IS NOT NULL AND ip_address != ''
  AND source_type != ''
  -- exclude multicast MACs (odd second nibble): switch FDB can carry
  -- multicast group entries that are not devices
  AND lower(substring(mac_address, 2, 1)) NOT IN ('1', '3', '5', '7', '9', 'b', 'd', 'f')
GROUP BY mac, ip, source_type;
