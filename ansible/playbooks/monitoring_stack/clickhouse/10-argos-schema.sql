-- Source of truth for Argos Milestone 1. Aether applies in production. Do not create users or grants.
-- Migration ledger row is inserted by the apply harness after this file succeeds (checksum of this file).

CREATE DATABASE IF NOT EXISTS argos;

CREATE TABLE IF NOT EXISTS argos.schema_migrations
(
    migration_id String,
    checksum FixedString(64),
    applied_at DateTime64(3, 'UTC'),
    milestone LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY migration_id;

CREATE TABLE IF NOT EXISTS argos.detector_checkpoint_history
(
    detector_id LowCardinality(String),
    detector_version String,
    cursor_kind LowCardinality(String),
    cursor_version String,
    cursor_payload String,
    ingestion_watermark Nullable(DateTime64(3, 'UTC')),
    sequence UInt64,
    cycle_id UUID,
    completed_at DateTime64(3, 'UTC'),
    baseline_revision String,
    baseline_hash FixedString(64),
    advancement_reason Enum8(
        'normal' = 1,
        'source_retention_gap' = 2
    ),
    lost_range_start Nullable(DateTime64(3, 'UTC')),
    lost_range_end Nullable(DateTime64(3, 'UTC')),
    source_retention_contract_version Nullable(String)
)
ENGINE = MergeTree
ORDER BY (detector_id, sequence);

CREATE TABLE IF NOT EXISTS argos.detector_runs
(
    run_id UUID,
    cycle_sequence UInt64,
    attempt UInt16,
    detector_id LowCardinality(String),
    detector_version String,
    binary_version String,
    window_start DateTime64(3, 'UTC'),
    window_end DateTime64(3, 'UTC'),
    baseline_revision String,
    baseline_hash FixedString(64),
    status Enum8(
        'running' = 1,
        'succeeded' = 2,
        'failed' = 3,
        'abandoned' = 4
    ),
    started_at DateTime64(3, 'UTC'),
    finished_at Nullable(DateTime64(3, 'UTC')),
    feature_count UInt64,
    finding_count UInt64,
    error_code LowCardinality(String),
    error_message String,
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(window_end)
ORDER BY run_id;

CREATE TABLE IF NOT EXISTS argos.network_pair_features
(
    feature_id FixedString(64),
    run_id UUID,
    detector_id LowCardinality(String),
    detector_version String,
    query_version String,
    evaluation_cutoff DateTime64(3, 'UTC'),
    window_start DateTime64(3, 'UTC'),
    window_end DateTime64(3, 'UTC'),
    source_ipv4 IPv4,
    destination_ipv4 IPv4,
    destination_port UInt16,
    protocol LowCardinality(String),
    observation_count UInt32,
    positive_interval_count UInt32,
    active_span_ms Int64,
    interval_median_ms Float64,
    interval_mad_ms Float64,
    payload_median_bytes Float64,
    payload_mad_bytes Float64,
    timing_score Float32,
    payload_score Float32,
    persistence_score Float32,
    score Float32,
    confidence Float32,
    is_expected UInt8,
    matched_rule_ids Array(String),
    baseline_revision String,
    baseline_hash FixedString(64),
    created_at DateTime64(3, 'UTC'),
    version UInt64,
    source_high_watermark DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (feature_id, run_id)
TTL toDateTime(created_at) + INTERVAL 365 DAY;

CREATE TABLE IF NOT EXISTS argos.findings
(
    finding_id FixedString(64),
    run_id UUID,
    detector_id LowCardinality(String),
    detector_version String,
    binary_version String,
    query_version String,
    evidence_schema_version String,
    domain LowCardinality(String),
    subject_type LowCardinality(String),
    subject_canonical String,
    first_seen_at DateTime64(3, 'UTC'),
    last_observed_at DateTime64(3, 'UTC'),
    last_evaluated_at DateTime64(3, 'UTC'),
    evaluation_window_start DateTime64(3, 'UTC'),
    evaluation_window_end DateTime64(3, 'UTC'),
    score Float32,
    confidence Float32,
    disposition Enum8(
        'candidate' = 1,
        'expected' = 2,
        'suppressed' = 3
    ),
    summary String,
    baseline_revision String,
    baseline_hash FixedString(64),
    created_at DateTime64(3, 'UTC'),
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (finding_id, run_id);

CREATE TABLE IF NOT EXISTS argos.finding_evidence
(
    finding_id FixedString(64),
    evidence_kind LowCardinality(String),
    evidence_schema_version String,
    payload String,
    payload_sha256 FixedString(64),
    run_id UUID,
    created_at DateTime64(3, 'UTC'),
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (finding_id, evidence_kind, run_id);

CREATE TABLE IF NOT EXISTS argos.feedback
(
    finding_id FixedString(64),
    decision Enum8(
        'benign' = 1,
        'suspicious' = 2,
        'confirmed_malicious' = 3,
        'invalid' = 4,
        'needs_more_data' = 5
    ),
    reason String,
    actor String,
    recorded_revision String,
    decided_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (finding_id, decided_at);

CREATE VIEW IF NOT EXISTS argos.detector_runs_current AS
SELECT
    tupleElement(winning_row, 1) AS run_id,
    tupleElement(winning_row, 2) AS cycle_sequence,
    tupleElement(winning_row, 3) AS attempt,
    tupleElement(winning_row, 4) AS detector_id,
    tupleElement(winning_row, 5) AS detector_version,
    tupleElement(winning_row, 6) AS binary_version,
    tupleElement(winning_row, 7) AS window_start,
    tupleElement(winning_row, 8) AS window_end,
    tupleElement(winning_row, 9) AS baseline_revision,
    tupleElement(winning_row, 10) AS baseline_hash,
    tupleElement(winning_row, 11) AS status,
    tupleElement(winning_row, 12) AS started_at,
    tupleElement(winning_row, 13) AS finished_at,
    tupleElement(winning_row, 14) AS feature_count,
    tupleElement(winning_row, 15) AS finding_count,
    tupleElement(winning_row, 16) AS error_code,
    tupleElement(winning_row, 17) AS error_message,
    tupleElement(winning_row, 18) AS version
FROM
(
    SELECT
        argMax(
            tuple(
                run_id,
                cycle_sequence,
                attempt,
                detector_id,
                detector_version,
                binary_version,
                window_start,
                window_end,
                baseline_revision,
                baseline_hash,
                status,
                started_at,
                finished_at,
                feature_count,
                finding_count,
                error_code,
                error_message,
                version
            ),
            version
        ) AS winning_row
    FROM argos.detector_runs
    GROUP BY run_id
);

CREATE VIEW IF NOT EXISTS argos.network_pair_features_current AS
SELECT
    tupleElement(winning_row, 1) AS feature_id,
    tupleElement(winning_row, 2) AS run_id,
    tupleElement(winning_row, 3) AS detector_id,
    tupleElement(winning_row, 4) AS detector_version,
    tupleElement(winning_row, 5) AS query_version,
    tupleElement(winning_row, 6) AS evaluation_cutoff,
    tupleElement(winning_row, 7) AS window_start,
    tupleElement(winning_row, 8) AS window_end,
    tupleElement(winning_row, 9) AS source_ipv4,
    tupleElement(winning_row, 10) AS destination_ipv4,
    tupleElement(winning_row, 11) AS destination_port,
    tupleElement(winning_row, 12) AS protocol,
    tupleElement(winning_row, 13) AS observation_count,
    tupleElement(winning_row, 14) AS positive_interval_count,
    tupleElement(winning_row, 15) AS active_span_ms,
    tupleElement(winning_row, 16) AS interval_median_ms,
    tupleElement(winning_row, 17) AS interval_mad_ms,
    tupleElement(winning_row, 18) AS payload_median_bytes,
    tupleElement(winning_row, 19) AS payload_mad_bytes,
    tupleElement(winning_row, 20) AS timing_score,
    tupleElement(winning_row, 21) AS payload_score,
    tupleElement(winning_row, 22) AS persistence_score,
    tupleElement(winning_row, 23) AS score,
    tupleElement(winning_row, 24) AS confidence,
    tupleElement(winning_row, 25) AS is_expected,
    tupleElement(winning_row, 26) AS matched_rule_ids,
    tupleElement(winning_row, 27) AS baseline_revision,
    tupleElement(winning_row, 28) AS baseline_hash,
    tupleElement(winning_row, 29) AS created_at,
    tupleElement(winning_row, 30) AS version,
    tupleElement(winning_row, 31) AS source_high_watermark
FROM
(
    SELECT
        argMax(
            tuple(
                feature_id,
                run_id,
                detector_id,
                detector_version,
                query_version,
                evaluation_cutoff,
                window_start,
                window_end,
                source_ipv4,
                destination_ipv4,
                destination_port,
                protocol,
                observation_count,
                positive_interval_count,
                active_span_ms,
                interval_median_ms,
                interval_mad_ms,
                payload_median_bytes,
                payload_mad_bytes,
                timing_score,
                payload_score,
                persistence_score,
                score,
                confidence,
                is_expected,
                matched_rule_ids,
                baseline_revision,
                baseline_hash,
                created_at,
                version,
                source_high_watermark
            ),
            version
        ) AS winning_row
    FROM argos.network_pair_features
    WHERE run_id IN
    (
        SELECT run_id
        FROM argos.detector_runs_current
        WHERE status = 'succeeded'
    )
    GROUP BY feature_id
);

CREATE VIEW IF NOT EXISTS argos.findings_current AS
SELECT
    tupleElement(winning_row, 1) AS finding_id,
    tupleElement(winning_row, 2) AS run_id,
    tupleElement(winning_row, 3) AS detector_id,
    tupleElement(winning_row, 4) AS detector_version,
    tupleElement(winning_row, 5) AS binary_version,
    tupleElement(winning_row, 6) AS query_version,
    tupleElement(winning_row, 7) AS evidence_schema_version,
    tupleElement(winning_row, 8) AS domain,
    tupleElement(winning_row, 9) AS subject_type,
    tupleElement(winning_row, 10) AS subject_canonical,
    tupleElement(winning_row, 11) AS first_seen_at,
    tupleElement(winning_row, 12) AS last_observed_at,
    tupleElement(winning_row, 13) AS last_evaluated_at,
    tupleElement(winning_row, 14) AS evaluation_window_start,
    tupleElement(winning_row, 15) AS evaluation_window_end,
    tupleElement(winning_row, 16) AS score,
    tupleElement(winning_row, 17) AS confidence,
    tupleElement(winning_row, 18) AS disposition,
    tupleElement(winning_row, 19) AS summary,
    tupleElement(winning_row, 20) AS baseline_revision,
    tupleElement(winning_row, 21) AS baseline_hash,
    tupleElement(winning_row, 22) AS created_at,
    tupleElement(winning_row, 23) AS version
FROM
(
    SELECT
        argMax(
            tuple(
                finding_id,
                run_id,
                detector_id,
                detector_version,
                binary_version,
                query_version,
                evidence_schema_version,
                domain,
                subject_type,
                subject_canonical,
                first_seen_at,
                last_observed_at,
                last_evaluated_at,
                evaluation_window_start,
                evaluation_window_end,
                score,
                confidence,
                disposition,
                summary,
                baseline_revision,
                baseline_hash,
                created_at,
                version
            ),
            version
        ) AS winning_row
    FROM argos.findings
    WHERE run_id IN
    (
        SELECT run_id
        FROM argos.detector_runs_current
        WHERE status = 'succeeded'
    )
    GROUP BY finding_id
);

CREATE VIEW IF NOT EXISTS argos.finding_evidence_current AS
SELECT
    tupleElement(winning_row, 1) AS finding_id,
    tupleElement(winning_row, 2) AS evidence_kind,
    tupleElement(winning_row, 3) AS evidence_schema_version,
    tupleElement(winning_row, 4) AS payload,
    tupleElement(winning_row, 5) AS payload_sha256,
    tupleElement(winning_row, 6) AS run_id,
    tupleElement(winning_row, 7) AS created_at,
    tupleElement(winning_row, 8) AS version
FROM
(
    SELECT
        argMax(
            tuple(
                finding_id,
                evidence_kind,
                evidence_schema_version,
                payload,
                payload_sha256,
                run_id,
                created_at,
                version
            ),
            version
        ) AS winning_row
    FROM argos.finding_evidence
    WHERE run_id IN
    (
        SELECT run_id
        FROM argos.detector_runs_current
        WHERE status = 'succeeded'
    )
    GROUP BY finding_id, evidence_kind
);

CREATE VIEW IF NOT EXISTS argos.detector_checkpoint_current AS
SELECT
    tupleElement(winning_row, 1) AS detector_id,
    tupleElement(winning_row, 2) AS detector_version,
    tupleElement(winning_row, 3) AS cursor_kind,
    tupleElement(winning_row, 4) AS cursor_version,
    tupleElement(winning_row, 5) AS cursor_payload,
    tupleElement(winning_row, 6) AS ingestion_watermark,
    tupleElement(winning_row, 7) AS sequence,
    tupleElement(winning_row, 8) AS cycle_id,
    tupleElement(winning_row, 9) AS completed_at,
    tupleElement(winning_row, 10) AS baseline_revision,
    tupleElement(winning_row, 11) AS baseline_hash,
    tupleElement(winning_row, 12) AS advancement_reason,
    tupleElement(winning_row, 13) AS lost_range_start,
    tupleElement(winning_row, 14) AS lost_range_end,
    tupleElement(winning_row, 15) AS source_retention_contract_version
FROM
(
    SELECT
        argMax(
            tuple(
                detector_id,
                detector_version,
                cursor_kind,
                cursor_version,
                cursor_payload,
                ingestion_watermark,
                sequence,
                cycle_id,
                completed_at,
                baseline_revision,
                baseline_hash,
                advancement_reason,
                lost_range_start,
                lost_range_end,
                source_retention_contract_version
            ),
            sequence
        ) AS winning_row
    FROM argos.detector_checkpoint_history
    GROUP BY detector_id
);
