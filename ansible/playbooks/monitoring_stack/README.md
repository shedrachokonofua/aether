# Monitoring Stack

This playbook will configure the monitoring stack virtual machine. The monitoring stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Otel Collector
- Prometheus
- Loki
- Tempo
- Grafana
- ClickHouse
- Fleet (osquery management)

## Usage

```bash
task configure:monitoring
```

## ClickHouse schema

- `clickhouse/*.sql` is copied to the host `clickhouse/init/` and mounted as `/docker-entrypoint-initdb.d` (runs only on empty data volumes).
- Live migrations that must not re-run on greenfield init live in `clickhouse-migrations/` (e.g. `09-zeek-conn-ingested-at.sql`). Apply those manually with `clickhouse-client` per the file runbook and `docs/monitoring.md`.
