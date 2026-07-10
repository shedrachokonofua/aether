# Network and Security Evidence

## ClickHouse

Zeek and Suricata logs are routed to ClickHouse instead of Loki. Query through
Grafana `POST /api/ds/query`; the helper accepts one comment-free statement
starting with `SELECT`, `SHOW`, `DESCRIBE`, `DESC`, or `EXPLAIN`:

```bash
G=.agents/skills/investigate-aether/scripts/grafana-read.bb
nix develop -c "$G" clickhouse \
  'SELECT Timestamp, note, msg, toString(src), toString(dst) FROM zeek.notice WHERE Timestamp >= now() - INTERVAL 1 HOUR ORDER BY Timestamp DESC LIMIT 50'
```

The database is the permission boundary. Grafana uses the local-only
`grafana_readonly` ClickHouse identity, whose IaC-owned role grants only schema
discovery and `SELECT` on `zeek.*` and `suricata.*`. The role also enforces
read-only mode plus execution, concurrency, memory, scan, and result limits.
Only `max_execution_time` is changeable in read-only mode, within a server-side
1-60 second constraint required by the Grafana ClickHouse client. The role has
no external-source `READ` or `WRITE` grants. The `aether` identity stays writable
for the OTel ingestion pipeline and is not used by Grafana.

Limit violations fail the query instead of returning silently truncated data.
Narrow the time range, aggregate, or query an hourly summary rather than raising
the limits during an investigation.

Current typed tables:

- Zeek: `conn`, `dns`, `http`, `ssl`, `weird`, `ssh`, `files`, `notice`
- Suricata: `alert`, `flow`, `dns`, `http`, `tls`, `anomaly`
- Hourly aggregates include connection, DNS, alert, source, flow, and event-type summaries

Use schemas from `ansible/playbooks/monitoring_stack/clickhouse/*.sql`; do not guess columns.

## Retention

Raw retention is table-specific:

- 14 days: Zeek connections, Suricata flows
- 30 days: DNS, HTTP, TLS/SSL, weird/anomaly data
- 90 days: Zeek SSH/files/notices and Suricata alerts
- 90-365 days: selected hourly aggregates

This corrects the oversimplified idea that every ClickHouse record lasts a year. Use hourly aggregates for longer windows when available.

## Known-good Starting SQL

```sql
SELECT count() FROM zeek.conn WHERE Timestamp >= now() - INTERVAL 1 HOUR

SELECT query, count() AS hits
FROM zeek.dns
WHERE Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY query ORDER BY hits DESC LIMIT 50

SELECT Timestamp, alert_severity, alert_signature,
       toString(src_ip), src_port, toString(dest_ip), dest_port
FROM suricata.alert
WHERE Timestamp >= now() - INTERVAL 24 HOUR
ORDER BY Timestamp DESC LIMIT 100
```

The provisioned IDS Monitoring and Security Triage dashboard JSON contains additional tested SQL.

## Other Security Surfaces

- Prometheus: Hubble drops, Trivy reports, namespace contracts, Tetragon metrics.
- Loki: Tetragon events, Wazuh logs, Keycloak login failures, Kubernetes audit-style application logs.
- Kubernetes: Cilium policies, Kyverno/PolicyReports, Trivy reports, Tetragon pods/policies.
- Fleet: host posture and query results, with partial enrollment caveats.
- VyOS/AdGuard/Caddy: use repo-defined host access and bounded logs for routing, DNS, or proxy questions.

Security digest alerts are often review queues, not proof of an active compromise. Correlate address, identity, timestamp, policy, and actual workload impact.
