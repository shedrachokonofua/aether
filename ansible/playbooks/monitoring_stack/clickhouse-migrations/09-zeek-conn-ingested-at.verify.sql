-- Verification helpers for zeek.conn.IngestedAt (A04B).
-- Run against ClickHouse after greenfield deploy or after 09 cutover.

-- 1) Column present
SELECT name, type
FROM system.columns
WHERE database = 'zeek' AND table = 'conn' AND name = 'IngestedAt';

-- 2) Existing / historical rows non-null (post-cutover backfill should match Timestamp ms)
SELECT
    count() AS rows,
    countIf(IngestedAt IS NULL) AS null_ingested_at,
    countIf(toDateTime64(Timestamp, 3, 'UTC') = IngestedAt) AS ingested_eq_event_ts
FROM zeek.conn;

-- 3) Fixture: old event time, fresh IngestedAt (requires write access to zeek.ingest)
-- INSERT INTO zeek.ingest (Timestamp, LogAttributes) VALUES (...)
-- then:
-- SELECT Timestamp, IngestedAt, dateDiff('second', Timestamp, IngestedAt) AS lag_s
-- FROM zeek.conn
-- WHERE uid = 'argos-a04b-fixture'
-- ORDER BY IngestedAt DESC
-- LIMIT 1;

-- 4) Half-open discovery windows (replace bounds)
-- SELECT count() FROM zeek.conn
-- WHERE IngestedAt >= toDateTime64('…', 3, 'UTC')
--   AND IngestedAt <  toDateTime64('…', 3, 'UTC');

-- 5) Live ingest still moving
SELECT count() AS conn_rows, max(IngestedAt) AS max_ingested_at FROM zeek.conn;
