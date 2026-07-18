# Monitoring Stack

This playbook configures the Fedora monitoring-stack VM and its Podman Quadlet services:

- Otel Collector
- Prometheus
- Loki
- GreptimeDB
- Tempo
- Grafana
- ClickHouse
- Fleet (osquery management)

## Usage

```bash
task configure:monitoring
```

## Storage layout

The VM deliberately separates the authoritative hot monitoring path from the
largest telemetry data:

| Guest storage | Proxmox storage | Filesystem and mount | Data |
| --- | --- | --- | --- |
| 256 GiB `virtio0` root disk | `local-lvm` | Btrfs `/` and `/home` | OS, Prometheus, ClickHouse, and service configuration |
| 1 TiB `virtio1` telemetry disk | `local-fast` | XFS `/var/lib/telemetry` | Loki data and GreptimeDB local metadata, WAL, and cache |
| SeaweedFS `greptime-telemetry` bucket | `hdd/seaweedfs` on Smith | S3 | GreptimeDB historical telemetry objects |

The telemetry disk is declared by `config/vm.yml` and
`tofu/home/monitoring_stack.tf`; `site.yml` formats and mounts it before the
Loki and GreptimeDB Quadlets start. Prometheus and ClickHouse intentionally
remain on the root disk so a telemetry-disk capacity or filesystem incident
does not also remove the authoritative metric and alert path. Do not
consolidate more stores onto `/var/lib/telemetry` without separate capacity
limits or another dedicated data disk.

Check the live layout from the guest:

```bash
findmnt -T /var/lib/telemetry
df -hT / /var/lib/telemetry
systemctl --user is-active prometheus clickhouse loki greptime
```

Deploy or reconcile the Greptime archive path after its OpenTofu resources:

```bash
task configure:greptime
```


## ClickHouse schema

- `clickhouse/*.sql` is copied to the host `clickhouse/init/` and mounted as `/docker-entrypoint-initdb.d` (runs only on empty data volumes).
- Live migrations that must not re-run on greenfield init live in `clickhouse-migrations/` (e.g. `09-zeek-conn-ingested-at.sql`). Apply those manually with `clickhouse-client` per the file runbook and `docs/monitoring.md`.
- `clickhouse/10-argos-schema.sql` is the accepted Argos `001_initial` schema. The
  `argos` task reapplies its idempotent DDL and records the immutable checksum in
  `argos.schema_migrations`; it must not be edited after first application.
- `estate_scan` ClickHouse schema in `ansible/playbooks/monitoring_stack/clickhouse/11-estate-scan-schema.sql`; apply with `task configure:estate-scan-schema` (also reconciles the `estate_scan` writer role/user).
- Writer password on the guest: `task configure:estate-scanner-credentials`.
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
