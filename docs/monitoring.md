# Monitoring

OpenTelemetry-native observability: ClickHouse on `monitoring-stack` (`10.0.2.3`, Niobe) stores metrics, logs, and traces; Grafana and HyperDX run in Kubernetes. The central OTel Collector receives OTLP and scrapes exporters itself.

## Architecture

```mermaid
flowchart TB
    Agent["Host and cluster OTel agents"] -->|OTLP| Collector["Central OTel Collector"]
    Exporters["Prometheus-format exporters"] -->|scrape| Collector
    Collector -->|logs, metrics, traces| ClickHouse[(ClickHouse)]
    Collector -->|specialized network logs| Typed[("Zeek / Suricata / network tables")]
    ClickHouse --> Disk[("2 TiB telemetry disk")]
    ClickHouse --> Grafana["Grafana in Kubernetes"]
    Typed --> Grafana
    ClickHouse --> HyperDX["HyperDX in Kubernetes"]
    Collector -->|temporary dual-write| Legacy[("Prometheus / Loki")]
    Legacy -->|historical backfill| ClickHouse
```

## Central Stack

| Component | Purpose |
| --- | --- |
| OTel Collector | Contrib 0.156.0; OTLP ingestion and Prometheus-format scraping with `metric_start_time`; exports all three signals to ClickHouse |
| ClickHouse | 26.6; unified `otel` telemetry database plus existing network/IDS SQL analytics |
| Grafana | Kubernetes-hosted dashboards and SQL alert evaluation, using only datasource UID `clickhouse` |
| HyperDX | Admin-only ClickStack exploration UI over ClickHouse, with local accounts |
| Prometheus / Loki | Temporary dual-write copies and historical backfill sources; no dashboard or alert queries |

Image pins and deployment lifecycle are declared in
`ansible/playbooks/monitoring_stack/site.yml`; collector routing and scrape jobs
are in `otel_config.yml.j2` in that directory.

### Data Retention

Capacity-plan history (2026-09-24 06:00 through 2026-10-24 10:00 UTC, end
exclusive) is preserved at five-minute resolution in
`s3://aether-db-dumps/capacity-prometheus/2026-10-24/` on SeaweedFS
(`https://s3.seaweed.home.shdr.ch`), in the existing backup-stack dump-mirror
path. `manifest.json` records queries, per-file ranges/counts and SHA256 checksums;
`manifest.sha256` verifies it. `LOADER.txt` and
`scripts/archive-prometheus-capacity.py rows` describe loading a separate
ClickHouse table without a TTL: the normal 30-day metrics TTL would delete this
history. This focused archive complements, rather than runs or replaces, the
user's `scripts/telemetry-migration` backfill.
Returned samples span 2026-09-24 06:05 through 2026-10-24 09:55 UTC;
the archive contains 40,386,780 samples in 854 gzip objects (117,373,223 bytes).

| Backend | Retention | Notes |
| --- | --- | --- |
| `otel.otel_logs` | 120 days | General logs |
| `otel.otel_traces` | 30 days | Distributed traces |
| `otel.otel_metrics_*` | 30 days | Gauge, sum, histogram, exponential histogram, and summary tables |
| `otel.hyperdx_sessions` | 30 days | Session replay |
| Network/IDS tables | Per table | Existing raw and aggregate TTLs remain separate from `otel` |

The `otel` tables use storage policy `telemetry`, rooted at
`/var/lib/telemetry/clickhouse`; `config/vm.yml` declares a 2 TiB telemetry disk.
DDL and storage configuration live in
`ansible/playbooks/monitoring_stack/clickhouse/20-otel-schema.sql` and
`clickhouse-config.d/aether-telemetry-storage.xml` in the same playbook directory.

Tempo, GreptimeDB, Janus, and VM Grafana have been removed. GreptimeDB's archive
bucket is retained, not an active telemetry archive; `tofu/home/kubernetes/db_backups.tf`
retires its credential-generation resources with `destroy = false`. Prometheus and Loki still receive a dual-written copy while
historical backfills run from `scripts/telemetry-migration`; nothing queries them
for dashboards or alerts. Remove them only after backfill completion.

### Grafana, HyperDX, and tenancy

`tofu/home/kubernetes/grafana.tf` declares Grafana 13.2.3, pinned plugins,
CloudNativePG Postgres state, and provisioning from `grafana/dashboards` and
`grafana/alerting` beneath that directory. The single datasource UID `clickhouse`
uses `https://clickhouse.home.shdr.ch` with `queryTimeout = 30`.

Grafana org 1 uses `grafana_readonly`; HyperDX uses `hyperdx_reader`; Holmes,
orion, and investigation scripts use `agent_reader`. Tenant organizations,
datasources, and service accounts are declared from `config/tenants.yml` in
`grafana.tf`; each datasource uses its `tenant_<name>` ClickHouse identity.
`clickhouse-access/otel-access.sql.j2` creates row policies on every `otel` table:
`service.namespace` scopes all signals, `vc-<tenant>/` ServiceName prefixes also
scope logs/session replay, and `service_namespace` metric attributes also scope
metrics. The server is fail-closed for users without row policies.

Grafana service-account tokens are written to OpenBao at `<tenant>/grafana`,
`assay/grafana-alerting`, and `aether/grafana-automation`; SOPS `grafana_sa_token`
holds the automation Viewer token.

`tofu/home/kubernetes/hyperdx.tf` declares the ClickStack chart in namespace
`hyperdx`, exposed at `https://hyperdx.home.shdr.ch`. HyperDX uses local accounts
only: keep its team admin-only, not a tenant access surface. Admin credentials
are in SOPS `hyperdx.admin_email` / `hyperdx.admin_password`. Its HTTPRoute sets
`X-Forwarded-Proto: https` for secure login cookies.

### Network observations

VyOS, QSS, and GigaHub exporters use the shared schema-v1 sealed-NDJSON
contract. Host agents tail only atomically sealed `.ndjson` files, retain
persistent cursors, delete files after accepted OTLP delivery, and route each
source through a dedicated `log.source` value into the replay-idempotent
`network.observations` ClickHouse table.

GigaHub host observations carry every `Device/Hosts` entry—MAC, IP, hostname,
active state, lease data, and normalized Ethernet/Wi-Fi interface—without
identity-valued Prometheus labels or exporter-side truncation. The low-cardinality
`gigahub_hosts_active_by_interface_type` metric answers aggregate activity.
The Aether role keeps `gigahub_observations_enabled` false while the deployed
package remains pinned to v0.2.0; enable it with the first compatible exporter
artifact to activate the prepared filelog and ClickHouse path.

### Zeek `conn.IngestedAt` (Argos ingestion cursor)

`zeek.conn.IngestedAt` is `DateTime64(3, 'UTC')` set by the typed-table materialized view as `now64(3)` when ClickHouse accepts the row into typed storage. It is **not** Zeek sensor event time (`Timestamp`) and **not** OTEL collection time.

| Topic | Contract |
| --- | --- |
| Greenfield DDL | `clickhouse/02-typed-tables.sql` + `clickhouse/03-materialized-views.sql` |
| Live cutover | `clickhouse-migrations/09-zeek-conn-ingested-at.sql` (shadow `conn_v2` + `EXCHANGE TABLES`, then recreate `conn_mv TO zeek.conn`; **not** in `docker-entrypoint-initdb.d`) |
| Historical rows | At cutover, `IngestedAt = toDateTime64(Timestamp, 3, 'UTC')` |
| Producer ack → typed visibility | OTEL `clickhouse/zeek` uses `async_insert: true` with `wait_for_async_insert=1`; MVs remain synchronous on INSERT. Successful exporter acknowledgement implies the typed `zeek.conn` row is query-visible. |
| Visibility SLO | Conservative **60s** (2× server `async_insert_busy_timeout_max_ms` of 30s). With wait-on-flush, post-ack visibility is immediate; the SLO bounds end-to-end batching delay for watermark planning. |
| Argos settle floor | `ARGOS_INGEST_SETTLE_SECONDS >= max(300, 2 × visibility_slo) = 300`. Default Argos `evaluation_interval` is 3600s; `2 × 60 < 3600` holds. |

**Cutover verification (after applying `09-…` on a live volume):**

1. Pre-cutover row: `IngestedAt` is non-null and equals event `Timestamp` (ms UTC).
2. Insert a fixture with an old event `Timestamp` after cutover; `IngestedAt` is near `now64(3)`, not the old event time.
3. Two fixtures on opposite half-open `IngestedAt` boundaries are each selected by exactly one `[start,end)` discovery window.
4. Live `count()` on `zeek.conn` keeps rising; OTEL Zeek exporter shows no insert errors; Grafana panels that filter on `Timestamp` are unchanged.
5. Stress: after an acknowledged insert, the typed row is visible before any configured safe cutoff derived from the visibility SLO.
6. No post-cutover row has `IngestedAt` earlier than the cutover boundary.

Do not apply `09-…` without an explicit live-change approval (pause producers per the SQL runbook header).

## Monitoring Agents

### VM Monitoring Agent

Fedora/Debian VMs use the `vm_monitoring_agent` Ansible role; NixOS guests use
`nix/modules/otel-agent.nix`. Both run a local OTel Collector and push telemetry
to the central OTLP endpoint. Exact receivers vary by host declaration.

**Collects:**

- Host metrics via hostmetrics receiver (CPU, memory, disk, network, filesystem, load)
- Container metrics via podman/docker receiver (auto-detected)
- Local exporter metrics via prometheus receiver (Caddy, app-specific)
- Journald logs (configurable units)
- File logs (configurable patterns)

**Features:**

- Everything exports via OTLP — no direct Prometheus scraping of VMs
- Immutable OS support (rpm-ostree, Bazzite)
- GPU metrics auto-detected (Nvidia SMI exporter installed automatically)
- Persistent cursor storage for reliable log delivery

**Service:** `aether-otel-collector`

### Certificate expiry and renewal health

Certificate coverage is split by the component that owns the certificate:

| Runtime | Source | Metrics path |
| --- | --- | --- |
| Ansible-managed VMs | Explicit step-ca leaf files, plus selected renewal services/timers | `certificate_monitoring` role → local OTEL Prometheus receiver |
| NixOS machine-cert users | `/etc/ssl/certs/machine.crt` and `step-ca-cert-renew.service` | `nix/modules/step-ca-cert.nix` → local OTEL Prometheus receiver |
| Kubernetes | cert-manager controller `certmanager_certificate_*` metrics | cluster OTel collector → central collector → ClickHouse |

The local file exporter watches only paths declared by the owning playbook or
Nix module; it does not scan directories or private keys. Grafana rules alert
at less than 30% of the certificate lifetime, on expired files, and when a
configured renewal service or timer is failed/down. Kubernetes uses
cert-manager's renewal timestamp because the cluster contains both long-lived
application certificates and short-lived Istio workload certificates.

Proxmox `pve-ssl.pem` is intentionally not included: Proxmox owns that
certificate and its renewal path. Proxmox hosts become part of this file-cert
coverage when the planned journal-gateway step-ca certificates are deployed.

### Host Monitoring Agent

Deployed to Proxmox hosts via `host_monitoring_agent` role. Exposes metrics scraped by the central OTEL Collector's prometheus receiver.

| Exporter       | Port | Metrics                                       |
| -------------- | ---- | --------------------------------------------- |
| Node Exporter  | 9100 | CPU, memory, disk I/O, network, filesystems   |
| SMART Exporter | 9633 | Disk health, temps, wear, reallocated sectors |

**Services:** `aether-node-exporter`, `aether-smartctl-exporter`

### Journal Forwarder

The agent-free hosts (five Proxmox hypervisors + the AWS/GCP cloud VMs) run no
local OTel agent, so their logs are collected pull-based by
`otel-journal-gatewayd-forwarder` on `monitoring-stack`. It polls each host's
`systemd-journal-gatewayd` (`:19531`) and ships OTLP logs to the local central
collector, which writes them to ClickHouse. Deploy with `task configure:journal-gateways`
(the gateways) and `task configure:journal-forwarder` (the collector side).

| Hop | Transport / authn |
| --- | --- |
| forwarder → Proxmox hosts | HTTPS mTLS. gatewayd serves plain HTTP on loopback; **ghostunnel** terminates client-cert mTLS on the mgmt IP (Debian systemd is openssl-built, so gatewayd's own `--trust` is unavailable). The trust anchor is the `pki-journal-client` intermediate — it signs exactly one leaf, so it *is* the authorization policy — plus an `--allow-cn` allowlist. |
| forwarder → cloud VMs | Plain HTTP bound to the routed WireGuard site IP (`10.1.0.10` AWS, `10.2.0.10` GCP, `10.3.0.10` OCI). WireGuard + the host nftables rule (only `10.0.2.3` may reach `:19531`) + the VyOS `CLOUD` zone are the authn boundary. Tailscale was retired on these nodes. |
| forwarder → OTLP | loopback `http://127.0.0.1:4318`, plain. |

The forwarder's client cert is minted by **vault-agent** (Ansible `openbao_agent`
role) from `pki-journal-client/issue/forwarder` via the dedicated
`journal-forwarder` cert-auth role (pinned to `monitoring-stack.home.shdr.ch`,
never the shared `aether-machine` role). Renewal restarts the forwarder; the
gatewayd server certs (step-ca `machine-bootstrap`) renew and restart ghostunnel.

Logs land in `otel.otel_logs` with **`ServiceName` = the source host** (matching
the fleet convention: VM agents set `service.name` = hostname). The forwarder
itself emits `service.name` = the systemd unit, so the central collector rewrites
it to the host (`transform/journal_forwarder_identity`, scoped by
`instance_type`); the unit is preserved as `journald_unit_name`. Host and unit
attributes can be queried through the ClickHouse resource/log attribute maps.
On a fresh deploy each source's cursor is seeded to the current journal tail,
so long-uptime hosts do not automatically backfill weeks of stale entries.

Metrics on `127.0.0.1:9091` (`ojgf_*`) are scraped by the VM agent; the
`Journal Forwarder` Grafana group alerts on poll-stale, poll-errors, and absent
(all `severity: warning`).

### vigil (cloud control-plane audit)

The control-plane audit layer (CloudTrail, GCP Cloud Audit, OCI Audit,
Tailscale state, Cloudflare audit logs) is collected by **vigil**, a Rust
forwarder (sibling repo `~/projects/vigil`) deployed as a single-replica
`serve` Deployment in the `cloud-audit` namespace. It polls provider audit
APIs on a per-collector cadence (5 min mutation feeds, daily posture
snapshots), normalizes into the contract in vigil `docs/schema.md`, and
ships OTLP logs and OTLP gauges (`vigil_*`) to ClickHouse through the collector.
Auth is keyless: pod SA token →
Keycloak federated-jwt (`aud=cloud-audit`) → per-provider read-only
federation; the two static tokens (Tailscale/Cloudflare) are read from
OpenBao per iteration. Heartbeat is the `vigil_collector_*` gauge triple
plus a per-run summary log line; the `cloud-audit-*` Grafana group alerts
on feed-absent/run-failed plus the estate-specific event rules
(warning-first, soak-then-promote). Deployment, Kyverno pod pin, and Cilium
egress pin live in `tofu/home/kubernetes/cloud_audit.tf`.

## API-Based Exporters

Running in the monitoring stack pod, scraped by the central OTEL Collector:

| Exporter     | Target                | Metrics                        |
| ------------ | --------------------- | ------------------------------ |
| PVE Exporter | Proxmox cluster API   | VM/CT status, storage, cluster |
| PBS Exporter | Proxmox Backup Server | Backup jobs, datastore usage   |

## Application Metrics

Collected by VM agents via prometheus receiver, pushed to central stack:

| Source           | VM              | Metrics                     |
| ---------------- | --------------- | --------------------------- |
| AdGuard Exporter | AdGuard LXCs    | DNS queries, blocked count  |
| HAProxy Exporter | Gateway Stack   | Backend health, connections |
| Postfix Exporter | Notifications Stack | Mail queue, delivery stats  |
| Caddy metrics    | Multiple        | Request rates, latencies    |

## Dashboards

Dashboard JSON is provisioned from `tofu/home/kubernetes/grafana/dashboards/`.
Dashboards query ClickHouse SQL, including metrics, logs, traces, and the
existing network/IDS tables. The table below describes dashboard purposes;
the provisioning directory is authoritative for the declared inventory.

| Dashboard       | Purpose                                       |
| --------------- | --------------------------------------------- |
| Proxmox Cluster | Host/VM/LXC resource usage                    |
| Hosts           | Node exporter metrics for Proxmox hosts       |
| Disk Health     | SMART metrics, disk temps, wear levels        |
| DNS             | AdGuard query stats, blocked domains          |
| Reverse Proxy   | Caddy request rates, latencies, errors        |
| HAProxy         | Backend health, connection stats              |
| PBS             | Backup job status, datastore usage            |
| UPS             | Power status, battery, load                   |
| Access Point    | UniFi AP client stats, signal strength        |
| IoT             | Home Assistant                                |
| qBittorrent     | Torrent stats, speeds                         |
| Synapse         | Matrix server metrics                         |
| Postfix         | Mail queue, delivery stats                    |
| ntfy            | Push notification delivery                    |
| IDS Monitoring  | Suricata alerts + Zeek analytics (ClickHouse) |
| Certificates    | Public TLS runway, VM/LXC machine identities, cert-manager inventory, renewal units, and certificate alerts (uid `certificates`) |
| Security Triage | **Single actionable security surface** — firing security-alert queue (`domain=security`) + per-head signal stats & recent-event tables (Suricata, Zeek, Hubble, Tetragon, Trivy, Wazuh, Keycloak) + drill-down links (uid `security-triage`) |
| Home            | Cross-cutting triage: firing alerts, certificate issues, namespace-contract risk map, saturation/headroom, signal-path health (uid `home`) |
| Site Fabric   | Aether site-fabric target health, WireGuard peer age and traffic, and CrowdSec decisions (uid `site-fabric`) |
| Deskplane v2 | Deskplane web data platform: scrape ops, cache, escalations, browser pool, event-loop lag, jobs, sessions, webhooks; SQL rules in `tofu/home/kubernetes/grafana/alerting/rules/deskplane.yml` are paused |

## Agent Investigations

The supported interactive investigation workflow is the repo-local
[`$investigate-aether`](../.agents/skills/investigate-aether/SKILL.md) skill. It
uses Grafana as the read-only correlation surface, then selects ClickHouse,
Kubernetes, Fleet, Talos, SSH, or a service API based on the symptom. Use
[`$navigate-aether`](../.agents/skills/navigate-aether/SKILL.md) first when the
component's placement or ownership is unclear.

From the repository root:

```bash
G=.agents/skills/investigate-aether/scripts/grafana-read.bb
nix develop -c "$G" dashboards
nix develop -c "$G" alerts        # active instances; omits DeadMansSwitch
nix develop -c "$G" alerts --all  # includes the intentional heartbeat
nix develop -c "$G" rules         # provisioned rule definitions
nix develop -c "$G" contact-points # receiver metadata; URLs are omitted
nix develop -c "$G" sql 'SELECT count() FROM otel.otel_logs WHERE Timestamp > now() - INTERVAL 1 HOUR'
```

The helper uses datasource UID `clickhouse` and obtains the automation Viewer
token from SOPS without printing it. Grafana's datasource uses the
`grafana_readonly` identity with server-enforced grants, row policies, and
resource limits; direct agent queries use `agent_reader`. Investigation remains
read-only. IaC remediation and any
explicitly approved live patch follow `AGENTS.md`.

The automated path is implemented by sibling
[`inquest`](https://gitlab.home.shdr.ch/so/inquest): Grafana dual-delivers every actionable
alert to Kestra, Inquest creates or updates `so/aether/incidents` issues, and
Holmes posts a read-only RCA for human verification. Aether owns Kestra, Holmes,
Grafana routing, secrets, and network policy; Inquest owns the flow IaC and
incident lifecycle. This path is separate from, and not a prerequisite for,
interactive `$investigate-aether` work. The older
[`agentic-incident-response.md`](exploration/agentic-incident-response.md)
document is a superseded AIAgent/Fleet exploration.

## Alerting

Alerts route through Apprise to ntfy for push notifications. Every
`apprise-*` contact point also contains the Inquest webhook receiver, so critical,
standard, digest, and security alerts are delivered to both their existing human
path and the automated incident path. `kuma-deadman` remains exclusively the
always-firing Uptime Kuma heartbeat; it is not an incident source.

### Severity Levels

| Severity | Routing          | Use Case                     |
| -------- | ---------------- | ---------------------------- |
| critical | apprise-critical | Immediate action required    |
| warning  | apprise-standard | Attention needed, not urgent |

### Alert Rules

| Alert                  | Severity | Condition                        |
| ---------------------- | -------- | -------------------------------- |
| Host Down              | critical | Proxmox node unreachable         |
| Disk Space Low         | critical | <10% free space                  |
| Disk SMART Unhealthy   | critical | SMART status failure             |
| GPU Thermal Throttling | critical | Hardware thermal slowdown active |
| Host High CPU          | warning  | >90% CPU for 5m                  |
| Host High Memory       | warning  | >90% memory for 5m               |
| VM High CPU            | warning  | >90% CPU for 5m                  |
| VM High Memory         | warning  | >90% memory for 5m               |
| Backup Stale           | warning  | Last backup >24h ago             |
| Kubernetes ReplicaSet Not Ready | warning  | Desired replicas exceed ready replicas for 15m |
| GPU High Temperature   | warning  | >85°C for 2m                     |
| GPU High Memory        | warning  | >95% VRAM for 5m                 |
| Smith Clocksource Regression | warning | talos-smith host system-CPU >30% for 15m — acpi_pm PIO-exit-storm tripwire (temporary; remove at next Talos bump) |

### App-level alert rules

App-specific SQL rules are provisioned alongside infrastructure rules from
`tofu/home/kubernetes/grafana/alerting/rules/`.
They carry `domain=media` (or their app domain) and route via the default
catch-all to `apprise-standard` unless they carry `channel`/`domain=security`
overrides. Current app rules:

| Alert | Severity | Condition | Source |
| --- | --- | --- | --- |
| Jellyfin SSO Auth Provider Broken | critical | `InvalidAuthProvider` in jellyfin ns [30m] > 0 | ClickHouse logs |
| Jellyfin Gelato Stream Resolution Failures | warning | `Invalid stream, skipping` [1h] > 5 | ClickHouse logs |
| Jellyfin Click-Play-No-Streams | warning | `SyncStreams finished … streams=0` [1h] > 0 | ClickHouse logs |
| Jellyfin strm Link Resolution Rot | warning | `Unable to find linked item` [1h] > 200 | ClickHouse logs |
| Jellyfin Server Down | critical | `jellyfin_up == 0` for 5m | ClickHouse metrics (rebelcore/jellyfin_exporter) |

Author rules against datasource UID `clickhouse` with SQL; PromQL/LogQL are no
longer dashboard or alert query languages in this deployment. Provisioning is
owned by the Kubernetes Grafana release, not the former VM provisioning tree.



## Alert routing contract

Alerts are routed by label, not by hard-coded receiver. Every rule carries
`severity` (`warning|critical`) and MAY carry `channel` (`page|digest` — an
explicit override), `domain` (`security|governance`), and — for
namespace-scoped SQL rules — contract labels `tier`, `owner`, and `criticality`
joined from the ClickHouse view `aether.namespace_contract`.

The view replaces the Prometheus recording rule and selects the latest
`kube_namespace_labels` attributes over a five-minute lookback from
`otel.otel_metrics_gauge` (DDL: `20-otel-schema.sql`). kube-state-metrics remains
the source of the namespace contract labels.

First-match routing tree (`tofu/home/kubernetes/grafana/alerting/notification-policies.yml`):

| Order | Match | Receiver | Cadence | Meaning |
|---|---|---|---|---|
| 1 | `alertname=DeadMansSwitch` | `kuma-deadman` | repeat 3m | heartbeat to the external Uptime-Kuma push monitor |
| 2 | `channel=page` | `apprise-critical` | default | non-negotiable pages (backup freshness, PSS-blocked, metrics-pipeline-dead) regardless of tier |
| 3 | `channel=digest` | `apprise-digest` | group 15m / repeat 24h | explicit review-class |
| 4 | `domain=security, severity=critical` | `apprise-critical` | default | security pages |
| 5 | `domain=security` | `apprise-security` | digest cadence | security review feed (ntfy `/security` + Matrix) |
| 6 | `criticality=low` | `apprise-digest` | digest cadence | guest/sandbox namespaces — no 3am pages for low-value workloads |
| 7 | `criticality=high` | `apprise-critical` | default | platform namespaces page even at `warning` |
| 8 | `severity=critical` | `apprise-critical` | default | catch-all critical |
| 9 | default | `apprise-standard` | default | everything else |

### Security triage

Each security signal is assigned exactly one bucket:

- **page** — Suricata sev-1 (post-soak), Tetragon escape-class policies
  (post-soak), Wazuh rule level ≥ 12 (post-soak), PSS `FailedCreate`.
- **digest** — Suricata sev-1/2 daily review, Zeek notices, Tetragon
  untrusted-tier policies, Trivy criticals in `backup=critical` /
  `exposure=public` namespaces, Keycloak login-failure bursts, Fleet
  failing-policy notifications (webhook → ntfy `/security`), Kyverno audit-fail
  summary.
- **forensics-only (deliberately no alert)** — Zeek conn/dns/http/ssl/weird,
  Suricata sev-3, Hubble flows, Fleet live/scheduled query history. Query these
  in Grafana/ClickHouse/Fleet; they are evidence, not pages.

### Argos network-beacon detector

Argos is a host-level Native AOT systemd worker on `monitoring-stack`; it is not
a Kubernetes workload and exposes no HTTP listener. Its configuration and
deployment harness live in `ansible/playbooks/monitoring_stack/argos.yml`.
`task configure:argos` installs the immutable CI artifact, renders the declared
baseline, applies the idempotent `001_initial` ClickHouse schema with a checksum
ledger, creates a least-privilege `argos` ClickHouse user, and runs the read-only
`argos check` preflight. The service is disabled by default.

The initial declared source contract is a 14-day `zeek.conn` retention with a
measured-safe 300-second settle delay (the ingestion visibility SLO is 60s), an
hourly evaluation boundary, a one-day feature lookback, and a ten-day aligned
bootstrap watermark. Review the current raw-retention horizon and expected
catch-up time before enabling; do not reuse the bootstrap watermark after it is
outside retention.

Before both `argos check` and service startup can report systemd readiness, Argos
reads the live `zeek.conn` TTL horizon from `system.tables.create_table_query`
and compares it with the declared `ARGOS_ZEEK_RETENTION_SECONDS`. A measured
TTL shorter than the declared value is a hard failure (exit code 9); a measured
TTL greater than or equal to it passes, and the measured value is logged.
Shortening the `zeek.conn` TTL without updating
`argos_zeek_retention_seconds` in `ansible/playbooks/monitoring_stack/site.yml`
therefore fails deployment preflight instead of silently creating blind spots.

Argos refuses to start with exit code 10 when `ARGOS_BOOTSTRAP_START` is already
outside the live retention horizon. This gate applies only while no durable
checkpoint exists. As the 14-day TTL window slides,
`argos_bootstrap_start` in `site.yml` becomes stale; refresh it to a currently
valid, interval-aligned instant in the same change that bumps `argos_version`.

If a running service falls behind the horizon, for example during a long outage,
it does not replay deleted data. It appends exactly one checkpoint with
`advancement_reason = 'source_retention_gap'`, `lost_range_start` set to the
abandoned watermark, `lost_range_end` set to the new watermark, and
`source_retention_contract_version = 'zeek-conn-ttl-v1'`, then resumes normal
cycles. This increments the `argos.detector.data_gaps` counter, allowing the
`argos-source-retention-gap` Grafana rule and the Security-Triage “Argos data
gaps (24h)” panel to fire. Any non-zero data-gap count means real evidence was
lost and requires review.

The Security-Triage “Argos candidate findings” panel resolves each finding's
source IPv4 through `network.mac_ip_history` for MAC and hostname, aggregating
with `argMax` over `last_seen`, and through `network.mac_first_seen` for the
device first-seen date. A companion stat panel reports the share of current
candidates that resolve. These tables are fed by sealed-NDJSON observations
from `vyos-exporter`, `gigahub-exporter`, and `qss-exporter` into
`network.observations`; an address never observed by any of those exporters
stays unattributed.

Both identity tables are `AggregatingMergeTree` tables whose parts merge
lazily, so queries against them must aggregate rather than select aggregate
columns raw. Grafana's `grafana_readonly` identity already holds `SELECT` on
`network.*` through `clickhouse_grafana_databases` in `site.yml`; no additional
grant was needed.

Security Triage contains the Argos checkpoint lag, retention headroom, failed
cycle, explicit data-gap, and candidate-finding panels. The corresponding
`argos-*` Grafana rules are deliberately provisioned with `isPaused: true` in
A10. After dashboard-only observation and restart recovery prove healthy, a
reviewed A11 change may unpause them. Candidate findings retain
`domain=security`, `severity=warning`, and `channel=digest`: their annotations
include the finding ID, detector version, and the Security Triage evidence link;
they never page in this milestone.

### Soak-then-promote

Every NEW page-class security rule ships as `severity: warning` (so it lands in
the digest via route 5) for 14 days. After a clean soak — zero unexplained hits
in the security ntfy history / PolicyReports — a single reviewed commit flips
`severity: warning` → `critical` on the promoted rule uids. Any noisy signal
gets its suppression added in the same commit.

### Suppression workflow

Suppressions are code, never live mutes. IDS suppressions live in the rule's
ClickHouse SQL literal — e.g. `ids-suricata-severity1` carries an
`alert_signature_id NOT IN (0 /* seed */)` list; append the SID there and
commit. This keeps every mute versioned and reviewable.

### Fleet policy & query management

Fleet posture is managed as code in `ansible/playbooks/monitoring_stack/fleet.yml`
(tag `fleet-config`), never in the Fleet UI. Policies (`/api/v1/fleet/spec/policies`)
and scheduled queries (`/api/v1/fleet/spec/queries`) are declared as `specs:`
lists and upsert on every playbook run. The failing-policy webhook posts to ntfy
`/security` (digest bucket). Re-running the playbook converges; UI edits are
overwritten.

### Fleet coverage & the migration rule

osquery enrolls into Fleet from two surfaces that share one enroll secret
(`fleet.enroll_secret` in SOPS; also mirrored to OpenBao `kv/data/aether/fleet`
for nix hosts) and an identical flag set:

- **NixOS (end-state):** `nix/modules/osquery-agent.nix`, enroll secret rendered
  by the OpenBao agent. First consumer: `intrusion-detection-stack`.
- **Ansible (bridge for un-migrated VMs):** `vm_monitoring_agent`'s `osquery.yml`,
  rolled out by `setup_vm_monitoring_agents.yml`. VyOS and rpm-ostree hosts
  self-exclude.

**Migration rule (definition-of-done for every Fedora→nix VM migration): import
`nix/modules/osquery-agent.nix` in the new host's config before decommissioning
the old Fedora VM. Fleet coverage must never regress across a migration.**

### Adding an app to the contract

A namespace's `hostnames` + contract labels (`tier`, `owner`, `backup`,
`exposure`, optional `criticality`) live in
`tofu/home/kubernetes/namespace_contracts.tf`. Adding a hostname there
automatically (a) mints a blackbox HTTP synthetic probe for `internal`,
`public`, and `tunnel` apps (wildcard `*.` hostnames are excluded — they are routing policy, not
probeable endpoints) via the `synthetic_probe_targets` output consumed by
`otel_config.yml.j2`, and (b) feeds the `probe_criticality`/`probe_exposure`
labels that decide whether a probe failure pages (`probe-failed-public`) or
digests (`probe-failed-internal`). No alert or scrape edit is needed per app.
