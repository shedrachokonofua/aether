-- Pre-computed aggregation views for dashboard performance
-- Using SummingMergeTree for automatic aggregation on merge

-- Hourly connection aggregates per source IP
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.conn_hourly
ENGINE = SummingMergeTree()
ORDER BY (hour, id_orig_h)
TTL hour + INTERVAL 365 DAY
AS SELECT
    toStartOfHour(Timestamp) AS hour,
    id_orig_h,
    count() AS connections,
    sum(orig_bytes) AS bytes_sent,
    sum(resp_bytes) AS bytes_received,
    uniqExact(id_resp_h) AS unique_destinations
FROM zeek.conn
GROUP BY hour, id_orig_h;

-- Hourly DNS query aggregates
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.dns_hourly
ENGINE = SummingMergeTree()
ORDER BY (hour, query)
TTL hour + INTERVAL 365 DAY
AS SELECT
    toStartOfHour(Timestamp) AS hour,
    query,
    count() AS queries,
    uniqExact(id_orig_h) AS unique_clients
FROM zeek.dns
GROUP BY hour, query;
