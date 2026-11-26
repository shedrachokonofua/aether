-- Host authentication events and per-host log heartbeat.
--
-- Grafana alert rules cannot scan raw otel.otel_logs bodies over a long
-- baseline (a 7-day body scan takes ~17s; 30 days exceeds the read-only
-- execution limit). These two small tables are filled at insert time so the
-- host-ssh-login-new-source, host-sudo-unexpected and host-logs-absent rules
-- read a few thousand rows instead.
--
-- Both materialized views run on every insert into otel.otel_logs. They use
-- only non-throwing functions: a failing view would fail the insert itself.
CREATE DATABASE IF NOT EXISTS aether;

CREATE TABLE IF NOT EXISTS aether.host_auth_events (
    `Timestamp` DateTime64(3) CODEC(Delta(8), ZSTD(1)),
    `Host` LowCardinality(String),
    `Kind` LowCardinality(String) COMMENT 'ssh_accepted | sudo_command | sudo_denied',
    `User` String COMMENT 'Login user (ssh) or invoking user (sudo)',
    `Source` String COMMENT 'Client address for ssh_accepted, empty otherwise',
    `Detail` String COMMENT 'Auth method (ssh) or command, truncated to 500 chars (sudo)'
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(Timestamp)
ORDER BY (Host, Kind, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL 400 DAY;

-- Two body shapes reach otel_logs. The Ansible agent and the journal forwarder
-- send the message as Body with LogAttributes['syslog.identifier']; the NixOS
-- agent sends the whole journal entry as a JSON Body. The identifier check
-- keeps web access logs that merely contain "Accepted " out of the table.
CREATE MATERIALIZED VIEW IF NOT EXISTS aether.host_auth_events_mv
TO aether.host_auth_events AS
SELECT
    toDateTime64(Timestamp, 3) AS Timestamp,
    ServiceName AS Host,
    multiIf(
        ident IN ('sshd', 'sshd-session'), 'ssh_accepted',
        match(msg, 'NOT in sudoers|incorrect password attempt|command not allowed|not allowed to run sudo'), 'sudo_denied',
        'sudo_command') AS Kind,
    if(Kind = 'ssh_accepted',
       extract(msg, '^Accepted \\S+ for (\\S+) from '),
       extract(msg, '^\\s*(\\S+) : ')) AS User,
    if(Kind = 'ssh_accepted', extract(msg, ' from (\\S+) port '), '') AS Source,
    if(Kind = 'ssh_accepted',
       extract(msg, '^Accepted (\\S+) for '),
       substring(extract(msg, 'COMMAND=(.*)$'), 1, 500)) AS Detail
FROM
(
    SELECT
        Timestamp,
        ServiceName,
        if(LogAttributes['syslog.identifier'] != '',
           LogAttributes['syslog.identifier'],
           JSONExtractString(Body, 'SYSLOG_IDENTIFIER')) AS ident,
        if(startsWith(Body, '{'), JSONExtractString(Body, 'MESSAGE'), Body) AS msg
    FROM otel.otel_logs
    WHERE position(ServiceName, '/') = 0
      AND (position(Body, 'Accepted ') > 0
           OR position(Body, 'COMMAND=') > 0
           OR position(Body, 'NOT in sudoers') > 0
           OR position(Body, 'incorrect password attempt') > 0)
)
WHERE (ident IN ('sshd', 'sshd-session') AND startsWith(msg, 'Accepted '))
   OR (ident = 'sudo' AND (position(msg, 'COMMAND=') > 0 OR position(msg, 'NOT in sudoers') > 0));

-- One row per host per hour that shipped any log line. A host is a source
-- whose agent sets os.type and whose service name is its own host name; this
-- excludes Kubernetes pods ('namespace/pod') and application services.
CREATE TABLE IF NOT EXISTS aether.host_log_heartbeat (
    `Host` LowCardinality(String),
    `Hour` DateTime,
    `Rows` UInt64
)
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(Hour)
ORDER BY (Host, Hour)
TTL Hour + INTERVAL 120 DAY;

CREATE MATERIALIZED VIEW IF NOT EXISTS aether.host_log_heartbeat_mv
TO aether.host_log_heartbeat AS
SELECT
    ServiceName AS Host,
    toStartOfHour(toDateTime(Timestamp)) AS Hour,
    count() AS Rows
FROM otel.otel_logs
WHERE position(ServiceName, '/') = 0
  AND ResourceAttributes['os.type'] != ''
  AND ResourceAttributes['host.name'] = ServiceName
GROUP BY Host, Hour;
