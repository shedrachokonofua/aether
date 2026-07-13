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
- `clickhouse/10-argos-schema.sql` is the accepted Argos `001_initial` schema. The
  `argos` task reapplies its idempotent DDL and records the immutable checksum in
  `argos.schema_migrations`; it must not be edited after first application.
- `clickhouse/11-estate-scan-schema.sql` is the estate scanner Phase 0 schema
  (`estate_scan` database). Apply with `task configure:estate-scan-schema`.
  After first application the `001_initial` checksum is immutable.

## Argos staged deployment

`task configure:argos` stages the pinned Native AOT binary, renders and validates
the baseline, reconciles the narrow ClickHouse identity, applies the schema, and
runs `argos check`. It does **not** enable `argos.service` or unpause Grafana
rules. Add `argos.clickhouse_password` (32+ characters) to encrypted SOPS before
the first run; OpenTofu mirrors it to `kv/data/aether/argos` for the existing
machine-auth secret path, while this Ansible bridge renders only the root-owned
systemd credential source.

The separately reviewed service enablement is:

```bash
task configure:argos -- -e argos_service_enabled=true
```

Do this only after the read-only preflight, schema/baseline review, and planned
dashboard-only bootstrap are accepted. The `argos-*` Grafana rules are shipped
paused and stay digest-only when later unpaused; no A10 rule has page routing.
