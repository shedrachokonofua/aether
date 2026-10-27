# Monitoring Stack

This playbook configures the Fedora monitoring-stack VM and its Podman Quadlet services:

- Otel Collector
- Prometheus
- Loki
- ClickHouse
- Fleet (osquery management)

Grafana and HyperDX now run in Kubernetes. Prometheus and Loki remain on the VM
while multi-day historical backfills read their data. Tempo, GreptimeDB, Janus,
and VM Grafana are retired; the playbook stops their units and removes only
their container quadlet definitions, not their volumes or data directories.

## Usage

```bash
task configure:monitoring
```

## Storage layout

The VM separates ClickHouse's existing network/security databases from its
largest telemetry tables:

| Guest storage | Proxmox storage | Filesystem and mount | Data |
| --- | --- | --- | --- |
| 256 GiB `virtio0` root disk | `local-lvm` | Btrfs `/` and `/home` | OS, Prometheus, ClickHouse network/security databases and access metadata, service configuration |
| 1 TiB `virtio1` telemetry disk | `local-fast` | XFS `/var/lib/telemetry` | ClickHouse `otel` tables, Loki data and retained GreptimeDB local metadata, WAL, and cache |
| Retained SeaweedFS `greptime-telemetry` bucket | `hdd/seaweedfs` on Smith | S3 | Archived GreptimeDB historical telemetry objects; no longer provisioned |

The telemetry disk is declared by `config/vm.yml` and
`tofu/home/monitoring_stack.tf`; `site.yml` formats and mounts it before the
ClickHouse and Loki Quadlets start. ClickHouse telemetry tables use
the `telemetry` storage policy: one volume on the `telemetry` disk at
`/var/lib/telemetry/clickhouse/`, bind-mounted at the same path with SELinux
labeling and image UID/GID 101 ownership (translated to subordinate host IDs
with `podman unshare chown`, not literal host UID 101). The default policy and named volume
on the root disk retain existing network/security databases and ClickHouse
metadata; this change does not move their parts. Capacity or filesystem failure
on the telemetry disk now affects telemetry queries and alerting. Account for
dual-write storage growth before decommissioning the older stores. ClickHouse
server memory is capped at 6 GiB while those stores share the 16 GiB VM; raise
that cap only after Prometheus and Loki are decommissioned.

Check the live layout from the guest:

```bash
findmnt -T /var/lib/telemetry
df -hT / /var/lib/telemetry
systemctl --user is-active prometheus clickhouse loki
```

The retired Greptime archive bucket and local state, Tempo data, and VM Grafana
volume are retained. OpenTofu forgets Greptime credential/config generators
using `removed` blocks with `destroy = false`, leaving existing generated files
untouched. No task deletes the archived bucket.


## ClickHouse schema

- `clickhouse/*.sql` is copied to the host `clickhouse/init/` and mounted as `/docker-entrypoint-initdb.d` (runs only on empty data volumes).
- Live migrations that must not re-run on greenfield init live in `clickhouse-migrations/` (e.g. `09-zeek-conn-ingested-at.sql`). Apply those manually with `clickhouse-client` per the file runbook and `docs/monitoring.md`.
- `clickhouse/10-argos-schema.sql` is the accepted Argos `001_initial` schema. The
  `argos` task reapplies its idempotent DDL and records the immutable checksum in
  `argos.schema_migrations`; it must not be edited after first application.
- `estate_scan` ClickHouse schema in `ansible/playbooks/monitoring_stack/clickhouse/11-estate-scan-schema.sql`; apply with `task configure:estate-scan-schema` (also reconciles the `estate_scan` writer role/user).
- Writer password on the guest: `task configure:estate-scanner-credentials`.
  After first application the `001_initial` checksum is immutable.
- `clickhouse/20-otel-schema.sql` owns `otel.otel_logs` (120 days),
  `otel.otel_traces` and `otel.hyperdx_sessions` (30 days), and gauge, sum,
  histogram, exponential histogram and summary metric tables (90 days).
  Columns follow collector-contrib v0.156.0's Map SQL templates; the collector
  must use `create_schema: false` and explicitly name
  `otel_metrics_exponential_histogram` (upstream defaults to `exp_histogram`).
  The idempotent DDL runs after readiness on every `clickhouse` or
  `clickhouse-otel` run, not just on greenfield init.
- `aether.namespace_contract` is an invoker-security view of the latest
  `kube_namespace_labels` gauges within five minutes. Verify the `namespace`
  and `label_aether_shdr_ch_*` Attributes keys against live data before cutover.
- `clickhouse-access/otel-access.sql.j2` reconciles `staff_reader_role`,
  `grafana_readonly`, `hyperdx_reader`, `agent_reader`, and one
  `tenant_<name>` identity per `config/tenants.yml`. Passwords are SHA-256 hashed
  from SOPS and rendered to a mode-0600, SELinux-labeled local SQL file.
  Readers reach ClickHouse through gateway IP `10.0.2.2`; Grafana and agent
  readers also allow local access. Grafana retains its existing databases;
  agents additionally read `zeek`, `suricata`, and `network`.
- Every telemetry table has permissive staff/admin policies and tenant policies.
  Logs/sessions match `service.namespace` or `vc-<tenant>/` service names;
  traces match `service.namespace`; metrics additionally match the point label
  `service_namespace`. Unmatched readers see no rows on policy-bearing tables.
  Tables without policies in existing databases are unaffected. Tenants receive
  only `SELECT otel.*`, readonly profiles (60 seconds, 2 GB, four concurrent
  queries, 100,000 result rows), and hourly quotas of 3,600 queries and 1,800
  execution seconds. Only `max_execution_time` is changeable within readonly
  constraints for Grafana's plugin.

Before applying, add `clickhouse.hyperdx_password`,
`clickhouse.agent_reader_password`, and each
`clickhouse.tenant_passwords.<name>` to encrypted `secrets/secrets.yml`; retain
the existing admin and Grafana passwords. Provision/mount the telemetry disk
before enabling telemetry ingestion. Reconcile both schema and access with:

```bash
nix develop --command bash -c 'cd ansible && ansible-playbook playbooks/monitoring_stack/site.yml --tags clickhouse,clickhouse-otel'
```

The playbook conditionally restarts ClickHouse after config/profile or Quadlet
changes before readiness and DDL reconciliation, so the bind mount and
`telemetry` policy are active before ingestion. The schema does not silently
migrate an existing table created on a different storage policy.

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
