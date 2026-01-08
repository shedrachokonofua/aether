-- Materialized views to transform Zeek logs into typed tables
-- These trigger synchronously on INSERT to zeek.ingest
-- Connection logs MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.conn_mv TO zeek.conn AS
SELECT
  Timestamp,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  LogAttributes ['proto'] AS proto,
  LogAttributes ['service'] AS service,
  toFloat64OrZero(LogAttributes ['duration']) AS duration,
  toUInt64OrZero(LogAttributes ['orig_bytes']) AS orig_bytes,
  toUInt64OrZero(LogAttributes ['resp_bytes']) AS resp_bytes,
  LogAttributes ['conn_state'] AS conn_state,
  LogAttributes ['history'] AS history,
  toUInt64OrZero(LogAttributes ['orig_pkts']) AS orig_pkts,
  toUInt64OrZero(LogAttributes ['resp_pkts']) AS resp_pkts
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%conn.log';

-- DNS logs MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.dns_mv TO zeek.dns AS
SELECT
  Timestamp,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  LogAttributes ['proto'] AS proto,
  LogAttributes ['query'] AS query,
  LogAttributes ['qclass_name'] AS qclass_name,
  LogAttributes ['qtype_name'] AS qtype_name,
  LogAttributes ['rcode_name'] AS rcode_name,
  LogAttributes ['AA'] = 'true' AS AA,
  LogAttributes ['TC'] = 'true' AS TC,
  LogAttributes ['RD'] = 'true' AS RD,
  LogAttributes ['RA'] = 'true' AS RA,
  LogAttributes ['rejected'] = 'true' AS rejected
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%dns.log';

-- HTTP logs MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.http_mv TO zeek.http AS
SELECT
  Timestamp,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  LogAttributes ['method'] AS method,
  LogAttributes ['host'] AS host,
  LogAttributes ['uri'] AS uri,
  LogAttributes ['user_agent'] AS user_agent,
  toUInt64OrZero(LogAttributes ['request_body_len']) AS request_body_len,
  toUInt64OrZero(LogAttributes ['response_body_len']) AS response_body_len,
  toUInt16OrZero(LogAttributes ['status_code']) AS status_code,
  LogAttributes ['status_msg'] AS status_msg,
  LogAttributes ['resp_mime_types'] AS resp_mime_types
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%http.log';

-- SSL logs MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.ssl_mv TO zeek.ssl AS
SELECT
  Timestamp,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  LogAttributes ['version'] AS version,
  LogAttributes ['cipher'] AS cipher,
  LogAttributes ['server_name'] AS server_name,
  LogAttributes ['established'] = 'true' AS established,
  LogAttributes ['ssl_history'] AS ssl_history,
  LogAttributes ['subject'] AS subject,
  LogAttributes ['issuer'] AS issuer,
  LogAttributes ['validation_status'] AS validation_status
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%ssl.log';

-- Weird events MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.weird_mv TO zeek.weird AS
SELECT
  Timestamp,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  LogAttributes ['name'] AS name,
  LogAttributes ['notice'] = 'true' AS notice,
  LogAttributes ['peer'] AS peer,
  LogAttributes ['source'] AS source
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%weird.log';

-- SSH logs MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.ssh_mv TO zeek.ssh AS
SELECT
  Timestamp,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  toUInt8OrZero(LogAttributes ['version']) AS version,
  toUInt16OrZero(LogAttributes ['auth_attempts']) AS auth_attempts,
  LogAttributes ['direction'] AS direction,
  LogAttributes ['client'] AS client,
  LogAttributes ['server'] AS server,
  LogAttributes ['auth_success'] = 'true' AS auth_success
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%ssh.log';

-- Files logs MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.files_mv TO zeek.files AS
SELECT
  Timestamp,
  LogAttributes ['fuid'] AS fuid,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  LogAttributes ['source'] AS source,
  toUInt8OrZero(LogAttributes ['depth']) AS depth,
  LogAttributes ['mime_type'] AS mime_type,
  LogAttributes ['filename'] AS filename,
  toUInt64OrZero(LogAttributes ['seen_bytes']) AS seen_bytes,
  toUInt64OrZero(LogAttributes ['total_bytes']) AS total_bytes,
  LogAttributes ['md5'] AS md5,
  LogAttributes ['sha1'] AS sha1
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%files.log';

-- Notice logs MV
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.notice_mv TO zeek.notice AS
SELECT
  Timestamp,
  LogAttributes ['uid'] AS uid,
  toIPv4OrDefault(LogAttributes ['id.orig_h']) AS id_orig_h,
  toUInt16OrZero(LogAttributes ['id.orig_p']) AS id_orig_p,
  toIPv4OrDefault(LogAttributes ['id.resp_h']) AS id_resp_h,
  toUInt16OrZero(LogAttributes ['id.resp_p']) AS id_resp_p,
  LogAttributes ['note'] AS note,
  LogAttributes ['msg'] AS msg,
  LogAttributes ['sub'] AS sub,
  toIPv4OrDefault(LogAttributes ['src']) AS src,
  toIPv4OrDefault(LogAttributes ['dst']) AS dst,
  toUInt16OrZero(LogAttributes ['p']) AS p,
  splitByChar(',', LogAttributes ['actions']) AS actions,
  toFloat64OrZero(LogAttributes ['suppress_for']) AS suppress_for
FROM
  zeek.ingest
WHERE
  LogAttributes ['log.file.name'] LIKE '%notice.log';