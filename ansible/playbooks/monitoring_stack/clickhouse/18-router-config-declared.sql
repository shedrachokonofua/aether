-- Router DECLARED config snapshots (drift detection, side B).
--
-- Published at router-apply time by `router-drift.py --publish-declared`:
-- the repo's declared config, rendered and REDACTED with the SAME rules the
-- router applies to the live side, so the two are textually comparable. The
-- nightly comparator diffs the latest declared row against the latest live row
-- (network.router_config_snapshots) entirely inside ClickHouse - no repo, no
-- secrets, no git in the Kestra pod.
--
-- "Drift" therefore means live-differs-from-last-applied-declared (deployed
-- intent vs live), which is the correct definition for an unattended alert;
-- unapplied repo edits are pending work, not drift, and are still caught
-- on-demand by `router-drift.py --clickhouse` (declared rendered from repo HEAD).
--
-- Keyed on sha256: an unchanged declared config collapses to one row; each
-- apply that changes it adds a row (provenance in git_sha). Direct INSERT
-- (not via the observations bus) - the publisher runs where the repo+secrets
-- already are.

CREATE TABLE IF NOT EXISTS network.router_config_declared (
    timestamp DateTime64(3),
    source_instance LowCardinality(String),
    git_sha String,
    sha256 String,
    line_count UInt32,
    config String
) ENGINE = ReplacingMergeTree(timestamp)
ORDER BY (source_instance, sha256)
TTL toDateTime(timestamp) + INTERVAL 90 DAY;
