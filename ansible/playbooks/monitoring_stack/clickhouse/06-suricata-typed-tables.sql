-- Typed Suricata tables with native column types for fast analytics
-- These tables are populated by MVs from suricata.ingest
-- Based on Suricata EVE JSON schema: https://docs.suricata.io/en/latest/output/eve/eve-json-output.html

-- Alert events (security alerts - most important for dashboards)
CREATE TABLE IF NOT EXISTS suricata.alert (
    Timestamp DateTime64(9),
    flow_id UInt64,
    src_ip IPv4,
    src_port UInt16,
    dest_ip IPv4,
    dest_port UInt16,
    proto LowCardinality(String),
    app_proto LowCardinality(String),
    -- Alert specific fields
    alert_action LowCardinality(String),
    alert_gid UInt32,
    alert_signature_id UInt32,
    alert_rev UInt32,
    alert_signature String,
    alert_category LowCardinality(String),
    alert_severity UInt8,
    -- Connection context
    in_iface LowCardinality(String),
    vlan Array(UInt16)
) ENGINE = MergeTree()
ORDER BY (Timestamp, alert_severity, src_ip)
TTL Timestamp + INTERVAL 90 DAY;

-- Flow events (high volume - connection records like Zeek conn)
CREATE TABLE IF NOT EXISTS suricata.flow (
    Timestamp DateTime64(9),
    flow_id UInt64,
    src_ip IPv4,
    src_port UInt16,
    dest_ip IPv4,
    dest_port UInt16,
    proto LowCardinality(String),
    app_proto LowCardinality(String),
    -- Flow specific fields
    flow_state LowCardinality(String),
    flow_reason LowCardinality(String),
    bytes_toserver UInt64,
    bytes_toclient UInt64,
    pkts_toserver UInt64,
    pkts_toclient UInt64,
    flow_start DateTime64(9),
    flow_end DateTime64(9),
    -- Interface/VLAN
    in_iface LowCardinality(String),
    vlan Array(UInt16)
) ENGINE = MergeTree()
ORDER BY (Timestamp, src_ip)
TTL Timestamp + INTERVAL 14 DAY;

-- DNS events
CREATE TABLE IF NOT EXISTS suricata.dns (
    Timestamp DateTime64(9),
    flow_id UInt64,
    src_ip IPv4,
    src_port UInt16,
    dest_ip IPv4,
    dest_port UInt16,
    proto LowCardinality(String),
    -- DNS specific fields
    dns_type LowCardinality(String),
    dns_id UInt16,
    dns_rrname String,
    dns_rrtype LowCardinality(String),
    dns_rcode LowCardinality(String),
    dns_rdata String,
    dns_ttl UInt32,
    -- Interface
    in_iface LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY (Timestamp, dns_rrname)
TTL Timestamp + INTERVAL 30 DAY;

-- HTTP events
CREATE TABLE IF NOT EXISTS suricata.http (
    Timestamp DateTime64(9),
    flow_id UInt64,
    src_ip IPv4,
    src_port UInt16,
    dest_ip IPv4,
    dest_port UInt16,
    proto LowCardinality(String),
    -- HTTP specific fields
    http_hostname String,
    http_url String,
    http_http_user_agent String,
    http_http_content_type LowCardinality(String),
    http_http_method LowCardinality(String),
    http_protocol LowCardinality(String),
    http_status UInt16,
    http_length UInt64,
    http_request_body_len UInt64,
    http_response_body_len UInt64,
    -- Interface
    in_iface LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY (Timestamp, http_hostname)
TTL Timestamp + INTERVAL 30 DAY;

-- TLS events
CREATE TABLE IF NOT EXISTS suricata.tls (
    Timestamp DateTime64(9),
    flow_id UInt64,
    src_ip IPv4,
    src_port UInt16,
    dest_ip IPv4,
    dest_port UInt16,
    proto LowCardinality(String),
    -- TLS specific fields
    tls_sni String,
    tls_version LowCardinality(String),
    tls_subject String,
    tls_issuerdn String,
    tls_fingerprint String,
    tls_ja3_hash String,
    tls_ja3s_hash String,
    -- Interface
    in_iface LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY (Timestamp, tls_sni)
TTL Timestamp + INTERVAL 30 DAY;

-- Anomaly events (protocol anomalies)
CREATE TABLE IF NOT EXISTS suricata.anomaly (
    Timestamp DateTime64(9),
    flow_id UInt64,
    src_ip IPv4,
    src_port UInt16,
    dest_ip IPv4,
    dest_port UInt16,
    proto LowCardinality(String),
    app_proto LowCardinality(String),
    -- Anomaly specific fields
    anomaly_type LowCardinality(String),
    anomaly_event LowCardinality(String),
    anomaly_layer LowCardinality(String),
    anomaly_code UInt32,
    -- Interface
    in_iface LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY (Timestamp, anomaly_type)
TTL Timestamp + INTERVAL 30 DAY;


