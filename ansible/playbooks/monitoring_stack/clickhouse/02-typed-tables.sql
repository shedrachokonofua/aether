-- Typed Zeek tables with native column types for fast analytics
-- These tables are populated by MVs from zeek.ingest
-- Connection logs (highest volume, ~70% of Zeek logs)
CREATE TABLE IF NOT EXISTS zeek.conn (
  Timestamp DateTime64(9),
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  proto LowCardinality(String),
  service LowCardinality(String),
  duration Float64,
  orig_bytes UInt64,
  resp_bytes UInt64,
  conn_state LowCardinality(String),
  history String,
  orig_pkts UInt64,
  resp_pkts UInt64
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, id_orig_h) TTL Timestamp + INTERVAL 14 DAY;

-- DNS logs (investigation gold)
CREATE TABLE IF NOT EXISTS zeek.dns (
  Timestamp DateTime64(9),
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  proto LowCardinality(String),
  query String,
  qclass_name LowCardinality(String),
  qtype_name LowCardinality(String),
  rcode_name LowCardinality(String),
  AA Bool,
  TC Bool,
  RD Bool,
  RA Bool,
  rejected Bool
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, query) TTL Timestamp + INTERVAL 30 DAY;

-- HTTP logs
CREATE TABLE IF NOT EXISTS zeek.http (
  Timestamp DateTime64(9),
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  method LowCardinality(String),
  host String,
  uri String,
  user_agent String,
  request_body_len UInt64,
  response_body_len UInt64,
  status_code UInt16,
  status_msg String,
  resp_mime_types String
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, host) TTL Timestamp + INTERVAL 30 DAY;

-- SSL/TLS logs (certificate tracking)
CREATE TABLE IF NOT EXISTS zeek.ssl (
  Timestamp DateTime64(9),
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  version LowCardinality(String),
  cipher LowCardinality(String),
  server_name String,
  established Bool,
  ssl_history String,
  subject String,
  issuer String,
  validation_status LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, server_name) TTL Timestamp + INTERVAL 30 DAY;

-- Weird events (anomalies/attacks)
CREATE TABLE IF NOT EXISTS zeek.weird (
  Timestamp DateTime64(9),
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  name LowCardinality(String),
  notice Bool,
  peer LowCardinality(String),
  source LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, name) TTL Timestamp + INTERVAL 30 DAY;

-- SSH logs (authentication tracking)
CREATE TABLE IF NOT EXISTS zeek.ssh (
  Timestamp DateTime64(9),
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  version UInt8,
  auth_attempts UInt16,
  direction LowCardinality(String),
  client String,
  server String,
  auth_success Bool
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, id_orig_h) TTL Timestamp + INTERVAL 90 DAY;

-- Files logs (file transfers with hashes)
CREATE TABLE IF NOT EXISTS zeek.files (
  Timestamp DateTime64(9),
  fuid String,
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  source LowCardinality(String),
  depth UInt8,
  mime_type LowCardinality(String),
  filename String,
  seen_bytes UInt64,
  total_bytes UInt64,
  md5 String,
  sha1 String
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, md5) TTL Timestamp + INTERVAL 90 DAY;

-- Notice logs (security alerts from Zeek)
CREATE TABLE IF NOT EXISTS zeek.notice (
  Timestamp DateTime64(9),
  uid String,
  id_orig_h IPv4,
  id_orig_p UInt16,
  id_resp_h IPv4,
  id_resp_p UInt16,
  note LowCardinality(String),
  msg String,
  sub String,
  src IPv4,
  dst IPv4,
  p UInt16,
  actions Array(String),
  suppress_for Float64
) ENGINE = MergeTree()
ORDER BY
  (Timestamp, note) TTL Timestamp + INTERVAL 90 DAY;