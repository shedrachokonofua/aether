-- Zeek ingest table with Null engine
-- Schema matches OTEL exporter INSERT statement columns
-- https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/clickhouseexporter/internal/sqltemplates/logs_table.sql
--
-- Null engine: accepts inserts, stores nothing
-- MVs trigger on INSERT and write to typed Zeek tables
-- Zero storage overhead - data only lives in typed tables

CREATE DATABASE IF NOT EXISTS zeek;

CREATE TABLE IF NOT EXISTS zeek.ingest (
    Timestamp DateTime64(9),
    TimestampTime DateTime DEFAULT toDateTime(Timestamp),
    TraceId String,
    SpanId String,
    TraceFlags UInt8,
    SeverityText LowCardinality(String),
    SeverityNumber UInt8,
    ServiceName LowCardinality(String),
    Body String,
    ResourceSchemaUrl LowCardinality(String),
    ResourceAttributes Map(LowCardinality(String), String),
    ScopeSchemaUrl LowCardinality(String),
    ScopeName String,
    ScopeVersion LowCardinality(String),
    ScopeAttributes Map(LowCardinality(String), String),
    LogAttributes Map(LowCardinality(String), String),
    EventName String
) ENGINE = Null;

