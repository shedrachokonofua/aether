-- Live cutover: add zeek.conn.IngestedAt via atomic shadow swap.
--
-- NOT copied into docker-entrypoint-initdb.d. Fresh installs get IngestedAt from
-- 02-typed-tables.sql + 03-materialized-views.sql already. Apply this file only
-- against an existing volume that still has pre-IngestedAt zeek.conn.
--
-- Runbook (ordered; do not skip pause):
--   1. Confirm current schema has no IngestedAt:
--        SELECT name FROM system.columns
--        WHERE database='zeek' AND table='conn' AND name='IngestedAt'
--      If the column exists, STOP — cutover already done.
--   2. Apply statements through "CREATE conn_mv_v2" and the backfill INSERT
--      (dual-write window: old MV → conn, new MV → conn_v2).
--   3. Pause / buffer Zeek→OTEL→ClickHouse producers (or stop OTEL clickhouse/zeek
--      exporter briefly) so ingest.ingest is quiet.
--   4. Re-run the backfill INSERT once more for catch-up.
--   5. DROP old zeek.conn_mv; EXCHANGE TABLES; DROP conn_mv_v2; recreate
--      zeek.conn_mv TO zeek.conn (do NOT only RENAME — ClickHouse MVs bind the
--      target table by name, so after EXCHANGE conn_mv_v2 still targets conn_v2).
--   6. Resume producers. Verify checklist in docs/monitoring.md.
--   7. After soak, DROP TABLE zeek.conn_v2 (holds pre-swap leftover under that name).
--
-- Suggested apply:
--   clickhouse-client --multiquery < clickhouse-migrations/09-zeek-conn-ingested-at.sql
-- (split at runbook pause points as needed).

-- Shadow typed table (matches post-cutover zeek.conn).
CREATE TABLE IF NOT EXISTS zeek.conn_v2
(
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
    resp_pkts UInt64,
    IngestedAt DateTime64(3, 'UTC')
)
ENGINE = MergeTree()
ORDER BY (Timestamp, id_orig_h)
TTL Timestamp + INTERVAL 14 DAY;

-- Dual-write MV: new rows get now64(3) IngestedAt into the shadow table.
CREATE MATERIALIZED VIEW IF NOT EXISTS zeek.conn_mv_v2 TO zeek.conn_v2 AS
SELECT
    Timestamp,
    LogAttributes['uid'] AS uid,
    toIPv4OrDefault(LogAttributes['id.orig_h']) AS id_orig_h,
    toUInt16OrZero(LogAttributes['id.orig_p']) AS id_orig_p,
    toIPv4OrDefault(LogAttributes['id.resp_h']) AS id_resp_h,
    toUInt16OrZero(LogAttributes['id.resp_p']) AS id_resp_p,
    LogAttributes['proto'] AS proto,
    LogAttributes['service'] AS service,
    toFloat64OrZero(LogAttributes['duration']) AS duration,
    toUInt64OrZero(LogAttributes['orig_bytes']) AS orig_bytes,
    toUInt64OrZero(LogAttributes['resp_bytes']) AS resp_bytes,
    LogAttributes['conn_state'] AS conn_state,
    LogAttributes['history'] AS history,
    toUInt64OrZero(LogAttributes['orig_pkts']) AS orig_pkts,
    toUInt64OrZero(LogAttributes['resp_pkts']) AS resp_pkts,
    now64(3) AS IngestedAt
FROM zeek.ingest
WHERE LogAttributes['log.file.name'] LIKE '%conn.log';

-- Historical rows: IngestedAt defaults to event Timestamp (not migration-time now).
INSERT INTO zeek.conn_v2
SELECT
    Timestamp,
    uid,
    id_orig_h,
    id_orig_p,
    id_resp_h,
    id_resp_p,
    proto,
    service,
    duration,
    orig_bytes,
    resp_bytes,
    conn_state,
    history,
    orig_pkts,
    resp_pkts,
    toDateTime64(Timestamp, 3, 'UTC') AS IngestedAt
FROM zeek.conn;

-- >>> RUNBOOK PAUSE: stop producers, re-run the INSERT above for catch-up, then continue. <<<

DROP TABLE IF EXISTS zeek.conn_mv;

EXCHANGE TABLES zeek.conn AND zeek.conn_v2;

-- MV target is name-bound: after EXCHANGE, conn_mv_v2 still writes TO zeek.conn_v2
-- (the leftover table). Drop and recreate against the live typed table name.
DROP TABLE IF EXISTS zeek.conn_mv_v2;

CREATE MATERIALIZED VIEW zeek.conn_mv TO zeek.conn AS
SELECT
    Timestamp,
    LogAttributes['uid'] AS uid,
    toIPv4OrDefault(LogAttributes['id.orig_h']) AS id_orig_h,
    toUInt16OrZero(LogAttributes['id.orig_p']) AS id_orig_p,
    toIPv4OrDefault(LogAttributes['id.resp_h']) AS id_resp_h,
    toUInt16OrZero(LogAttributes['id.resp_p']) AS id_resp_p,
    LogAttributes['proto'] AS proto,
    LogAttributes['service'] AS service,
    toFloat64OrZero(LogAttributes['duration']) AS duration,
    toUInt64OrZero(LogAttributes['orig_bytes']) AS orig_bytes,
    toUInt64OrZero(LogAttributes['resp_bytes']) AS resp_bytes,
    LogAttributes['conn_state'] AS conn_state,
    LogAttributes['history'] AS history,
    toUInt64OrZero(LogAttributes['orig_pkts']) AS orig_pkts,
    toUInt64OrZero(LogAttributes['resp_pkts']) AS resp_pkts,
    now64(3) AS IngestedAt
FROM zeek.ingest
WHERE LogAttributes['log.file.name'] LIKE '%conn.log';

-- After verification soak (see docs/monitoring.md):
-- DROP TABLE IF EXISTS zeek.conn_v2;
