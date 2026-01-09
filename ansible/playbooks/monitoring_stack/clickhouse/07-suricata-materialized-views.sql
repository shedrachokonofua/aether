-- Materialized views to transform Suricata logs into typed tables
-- These trigger synchronously on INSERT to suricata.ingest
-- EVE JSON fields come as nested JSON objects from OTEL, use JSONExtract functions

-- Alert events MV
-- Note: vlan comes as JSON array string like "[3,4]" from OTEL
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.alert_mv TO suricata.alert AS
SELECT
    Timestamp,
    toUInt64OrZero(LogAttributes['flow_id']) AS flow_id,
    toIPv4OrDefault(LogAttributes['src_ip']) AS src_ip,
    toUInt16OrZero(LogAttributes['src_port']) AS src_port,
    toIPv4OrDefault(LogAttributes['dest_ip']) AS dest_ip,
    toUInt16OrZero(LogAttributes['dest_port']) AS dest_port,
    LogAttributes['proto'] AS proto,
    LogAttributes['app_proto'] AS app_proto,
    JSONExtractString(LogAttributes['alert'], 'action') AS alert_action,
    JSONExtractUInt(LogAttributes['alert'], 'gid') AS alert_gid,
    JSONExtractUInt(LogAttributes['alert'], 'signature_id') AS alert_signature_id,
    JSONExtractUInt(LogAttributes['alert'], 'rev') AS alert_rev,
    JSONExtractString(LogAttributes['alert'], 'signature') AS alert_signature,
    JSONExtractString(LogAttributes['alert'], 'category') AS alert_category,
    toUInt8(JSONExtractUInt(LogAttributes['alert'], 'severity')) AS alert_severity,
    LogAttributes['in_iface'] AS in_iface,
    JSONExtract(LogAttributes['vlan'], 'Array(UInt16)') AS vlan
FROM suricata.ingest
WHERE LogAttributes['event_type'] = 'alert';

-- Flow events MV
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.flow_mv TO suricata.flow AS
SELECT
    Timestamp,
    toUInt64OrZero(LogAttributes['flow_id']) AS flow_id,
    toIPv4OrDefault(LogAttributes['src_ip']) AS src_ip,
    toUInt16OrZero(LogAttributes['src_port']) AS src_port,
    toIPv4OrDefault(LogAttributes['dest_ip']) AS dest_ip,
    toUInt16OrZero(LogAttributes['dest_port']) AS dest_port,
    LogAttributes['proto'] AS proto,
    LogAttributes['app_proto'] AS app_proto,
    JSONExtractString(LogAttributes['flow'], 'state') AS flow_state,
    JSONExtractString(LogAttributes['flow'], 'reason') AS flow_reason,
    JSONExtractUInt(LogAttributes['flow'], 'bytes_toserver') AS bytes_toserver,
    JSONExtractUInt(LogAttributes['flow'], 'bytes_toclient') AS bytes_toclient,
    JSONExtractUInt(LogAttributes['flow'], 'pkts_toserver') AS pkts_toserver,
    JSONExtractUInt(LogAttributes['flow'], 'pkts_toclient') AS pkts_toclient,
    parseDateTime64BestEffortOrZero(JSONExtractString(LogAttributes['flow'], 'start')) AS flow_start,
    parseDateTime64BestEffortOrZero(JSONExtractString(LogAttributes['flow'], 'end')) AS flow_end,
    LogAttributes['in_iface'] AS in_iface,
    JSONExtract(LogAttributes['vlan'], 'Array(UInt16)') AS vlan
FROM suricata.ingest
WHERE LogAttributes['event_type'] = 'flow';

-- DNS events MV
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.dns_mv TO suricata.dns AS
SELECT
    Timestamp,
    toUInt64OrZero(LogAttributes['flow_id']) AS flow_id,
    toIPv4OrDefault(LogAttributes['src_ip']) AS src_ip,
    toUInt16OrZero(LogAttributes['src_port']) AS src_port,
    toIPv4OrDefault(LogAttributes['dest_ip']) AS dest_ip,
    toUInt16OrZero(LogAttributes['dest_port']) AS dest_port,
    LogAttributes['proto'] AS proto,
    JSONExtractString(LogAttributes['dns'], 'type') AS dns_type,
    toUInt16(JSONExtractUInt(LogAttributes['dns'], 'id')) AS dns_id,
    JSONExtractString(LogAttributes['dns'], 'rrname') AS dns_rrname,
    JSONExtractString(LogAttributes['dns'], 'rrtype') AS dns_rrtype,
    JSONExtractString(LogAttributes['dns'], 'rcode') AS dns_rcode,
    JSONExtractString(LogAttributes['dns'], 'rdata') AS dns_rdata,
    JSONExtractUInt(LogAttributes['dns'], 'ttl') AS dns_ttl,
    LogAttributes['in_iface'] AS in_iface
FROM suricata.ingest
WHERE LogAttributes['event_type'] = 'dns';

-- HTTP events MV
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.http_mv TO suricata.http AS
SELECT
    Timestamp,
    toUInt64OrZero(LogAttributes['flow_id']) AS flow_id,
    toIPv4OrDefault(LogAttributes['src_ip']) AS src_ip,
    toUInt16OrZero(LogAttributes['src_port']) AS src_port,
    toIPv4OrDefault(LogAttributes['dest_ip']) AS dest_ip,
    toUInt16OrZero(LogAttributes['dest_port']) AS dest_port,
    LogAttributes['proto'] AS proto,
    JSONExtractString(LogAttributes['http'], 'hostname') AS http_hostname,
    JSONExtractString(LogAttributes['http'], 'url') AS http_url,
    JSONExtractString(LogAttributes['http'], 'http_user_agent') AS http_http_user_agent,
    JSONExtractString(LogAttributes['http'], 'http_content_type') AS http_http_content_type,
    JSONExtractString(LogAttributes['http'], 'http_method') AS http_http_method,
    JSONExtractString(LogAttributes['http'], 'protocol') AS http_protocol,
    toUInt16(JSONExtractUInt(LogAttributes['http'], 'status')) AS http_status,
    JSONExtractUInt(LogAttributes['http'], 'length') AS http_length,
    JSONExtractUInt(LogAttributes['http'], 'request_body_len') AS http_request_body_len,
    JSONExtractUInt(LogAttributes['http'], 'response_body_len') AS http_response_body_len,
    LogAttributes['in_iface'] AS in_iface
FROM suricata.ingest
WHERE LogAttributes['event_type'] = 'http';

-- TLS events MV
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.tls_mv TO suricata.tls AS
SELECT
    Timestamp,
    toUInt64OrZero(LogAttributes['flow_id']) AS flow_id,
    toIPv4OrDefault(LogAttributes['src_ip']) AS src_ip,
    toUInt16OrZero(LogAttributes['src_port']) AS src_port,
    toIPv4OrDefault(LogAttributes['dest_ip']) AS dest_ip,
    toUInt16OrZero(LogAttributes['dest_port']) AS dest_port,
    LogAttributes['proto'] AS proto,
    JSONExtractString(LogAttributes['tls'], 'sni') AS tls_sni,
    JSONExtractString(LogAttributes['tls'], 'version') AS tls_version,
    JSONExtractString(LogAttributes['tls'], 'subject') AS tls_subject,
    JSONExtractString(LogAttributes['tls'], 'issuerdn') AS tls_issuerdn,
    JSONExtractString(LogAttributes['tls'], 'fingerprint') AS tls_fingerprint,
    JSONExtractString(LogAttributes['tls'], 'ja3', 'hash') AS tls_ja3_hash,
    JSONExtractString(LogAttributes['tls'], 'ja3s', 'hash') AS tls_ja3s_hash,
    LogAttributes['in_iface'] AS in_iface
FROM suricata.ingest
WHERE LogAttributes['event_type'] = 'tls';

-- Anomaly events MV
CREATE MATERIALIZED VIEW IF NOT EXISTS suricata.anomaly_mv TO suricata.anomaly AS
SELECT
    Timestamp,
    toUInt64OrZero(LogAttributes['flow_id']) AS flow_id,
    toIPv4OrDefault(LogAttributes['src_ip']) AS src_ip,
    toUInt16OrZero(LogAttributes['src_port']) AS src_port,
    toIPv4OrDefault(LogAttributes['dest_ip']) AS dest_ip,
    toUInt16OrZero(LogAttributes['dest_port']) AS dest_port,
    LogAttributes['proto'] AS proto,
    LogAttributes['app_proto'] AS app_proto,
    JSONExtractString(LogAttributes['anomaly'], 'type') AS anomaly_type,
    JSONExtractString(LogAttributes['anomaly'], 'event') AS anomaly_event,
    JSONExtractString(LogAttributes['anomaly'], 'layer') AS anomaly_layer,
    JSONExtractUInt(LogAttributes['anomaly'], 'code') AS anomaly_code,
    LogAttributes['in_iface'] AS in_iface
FROM suricata.ingest
WHERE LogAttributes['event_type'] = 'anomaly';

