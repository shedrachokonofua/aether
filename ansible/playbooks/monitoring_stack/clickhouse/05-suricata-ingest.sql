-- Suricata ingest table with Null engine
-- Schema matches OTEL exporter INSERT statement columns
-- Same pattern as Zeek: Null engine accepts inserts, MVs route to typed tables

CREATE DATABASE IF NOT EXISTS suricata;

CREATE TABLE IF NOT EXISTS suricata.ingest (
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


