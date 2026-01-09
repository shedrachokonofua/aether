-- Pre-aggregated views for Suricata dashboard performance
-- SummingMergeTree automatically sums values during background merges
-- Hourly alert aggregates by severity and signature
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.alert_hourly ENGINE = SummingMergeTree()
ORDER BY
    (hour, alert_severity, alert_signature) TTL hour + INTERVAL 365 DAY AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    alert_severity,
    alert_signature,
    alert_category,
    count() AS alert_count
FROM
    suricata.alert
GROUP BY
    hour,
    alert_severity,
    alert_signature,
    alert_category;

-- Hourly alert aggregates by source IP (for top attackers)
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.alert_by_src_hourly ENGINE = SummingMergeTree()
ORDER BY
    (hour, src_ip, alert_severity) TTL hour + INTERVAL 90 DAY AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    src_ip,
    alert_severity,
    count() AS alert_count
FROM
    suricata.alert
GROUP BY
    hour,
    src_ip,
    alert_severity;

-- Hourly flow aggregates by protocol
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.flow_hourly ENGINE = SummingMergeTree()
ORDER BY
    (hour, proto, app_proto) TTL hour + INTERVAL 90 DAY AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    proto,
    app_proto,
    count() AS flow_count,
    sum(bytes_toserver) AS bytes_toserver,
    sum(bytes_toclient) AS bytes_toclient,
    sum(pkts_toserver) AS pkts_toserver,
    sum(pkts_toclient) AS pkts_toclient
FROM
    suricata.flow
GROUP BY
    hour,
    proto,
    app_proto;

-- Hourly event type counts (for overview pie chart)
-- This uses a different approach - stores counts per event type
CREATE TABLE IF NOT EXISTS suricata.event_type_hourly (
    hour DateTime,
    event_type LowCardinality(String),
    event_count UInt64
) ENGINE = SummingMergeTree()
ORDER BY
    (hour, event_type) TTL hour + INTERVAL 90 DAY;

-- Populate event type counts from each typed table
-- Alert events
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.event_type_alert_mv TO suricata.event_type_hourly AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    'alert' AS event_type,
    count() AS event_count
FROM
    suricata.alert
GROUP BY
    hour;

-- Flow events
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.event_type_flow_mv TO suricata.event_type_hourly AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    'flow' AS event_type,
    count() AS event_count
FROM
    suricata.flow
GROUP BY
    hour;

-- DNS events
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.event_type_dns_mv TO suricata.event_type_hourly AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    'dns' AS event_type,
    count() AS event_count
FROM
    suricata.dns
GROUP BY
    hour;

-- HTTP events
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.event_type_http_mv TO suricata.event_type_hourly AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    'http' AS event_type,
    count() AS event_count
FROM
    suricata.http
GROUP BY
    hour;

-- TLS events
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.event_type_tls_mv TO suricata.event_type_hourly AS
SELECT
    toStartOfHour(Timestamp) AS hour,
    'tls' AS event_type,
    count() AS event_count
FROM
    suricata.tls
GROUP BY
    hour;