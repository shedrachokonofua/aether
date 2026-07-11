# Grafana Investigation Surface

Grafana is the primary correlation and read-only API surface at `https://grafana.home.shdr.ch`. The provisioned Viewer service-account token can read dashboards, alerts, and datasource results but must not mutate them.

## Access

From the repo root, prefer the helper:

```bash
nix develop -c .agents/skills/investigate-aether/scripts/grafana-read.bb health
```

For a manual request, decrypt only into a shell variable and never print it:

```bash
TOKEN=$(sops -d secrets/secrets.yml | yq -r '.grafana_sa_token')
curl -fsS -H "Authorization: Bearer $TOKEN" \
  https://grafana.home.shdr.ch/api/datasources
```

## Discovery

| Need | API |
| --- | --- |
| Health | `GET /api/health` |
| Datasources and current UIDs | `GET /api/datasources` |
| Datasource by name | `GET /api/datasources/name/<Name>` |
| Dashboards | `GET /api/search?type=dash-db&limit=200` |
| Dashboard model/panel queries | `GET /api/dashboards/uid/<uid>` |
| Provisioned alert rules | `GET /api/v1/provisioning/alert-rules` |
| Provisioned contact points | `GET /api/v1/provisioning/contact-points` |
| Active alert instances | `GET /api/alertmanager/grafana/api/v2/alerts` |

Never hardcode generated Prometheus or Tempo UIDs. Loki and ClickHouse currently have explicit UIDs, but discovery is still cheap and safer.

## Live Dashboard Entry Points

Discover current UIDs before opening them. The live Grafana API returned these
useful dashboard groups on 2026-07-09:

- Home: cross-cutting availability, saturation, backups, security, and certs
- Kubernetes: nodes, workloads, restarts, requests, GPU, network, scheduling
- Security Triage: actionable and review-class security signals
- IDS Monitoring: Zeek and Suricata drill-down
- Proxmox Cluster, Hosts, Disk Health, Ceph, and Proxmox Backup Server
- DNS, Reverse Proxy, HAProxy, UPS, Synapse, Postfix, ntfy, and qBittorrent

Existing panel queries are known-good starting points. Export the dashboard model and adapt a panel query before inventing a new one.

Do not confuse live persistence with reproducible provisioning. The current repo
dashboard directory contains Home, Virtual Machines, Ceph, Kubernetes, Security
Triage, and IDS Monitoring JSON. Several other live dashboards above persist in
Grafana but are not present in that directory, while the declared Virtual
Machines dashboard was not returned by the live search on 2026-07-09. Report
that as an IaC/live drift gap when it matters; use `/api/search` as the source of
truth for what can be opened during an investigation.

## Alerts

Summarize/group active alerts before dumping instances. `DeadMansSwitch` is intentionally active and should be reported as heartbeat state, not an incident. Preserve rule labels such as `severity`, `domain`, `channel`, `criticality`, `namespace`, and `alertname` when judging routing and impact.

Use `grafana-read.bb contact-points` to inspect receiver identity and type without
printing receiver settings or secret-bearing webhook URLs.

An alert in `Error` state (distinct from `Firing`) usually means its query failed, not that an incident is active. A Loki rule that trips `maximum number of series (500) reached` has a malformed query (e.g. a bare `count_over_time(...)` with no `sum()` wrapper) — route it to the alert owner as an authoring bug, not an outage. Likewise, a benign high-volume signal such as jellyfin's `InvalidAuthProvider` (normal `jellyfin-plugin-sso` log noise, not failed logins) is not an incident.

If Grafana itself is unhealthy, query the backing service or the monitoring VM only after proving the Grafana path failed. A transient readiness failure should be retried before declaring an outage.

## Provisioning Sources

- Datasources: `ansible/playbooks/monitoring_stack/grafana/provisioning/datasources/`
- Dashboards: `ansible/playbooks/monitoring_stack/grafana/provisioning/dashboards/`
- Alerts and routing: `ansible/playbooks/monitoring_stack/grafana/provisioning/alerting/`
- Public viewer token: `grafana_sa_token` in SOPS, never `grafana_password`
