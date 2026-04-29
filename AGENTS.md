# Agent guide — aether

Private cloud IaC. Code is the source of truth. Docs drift; the repo doesn't.

## Tooling

This is a **Nix + go-task** workspace. All CLI tools come from `flake.nix` — do not `brew install` or `pip install` anything.

- Enter the dev shell: `nix develop` (or use direnv). Inside it: `tofu`, `ansible`, `sops`, `bao`, `kubectl`, `talosctl`, `step`, `aws`, `yq`, `jq`, `task`, etc.
- **Run every command inside the dev shell.** None of these tools exist on the bare host. If you're not sure direnv is active, wrap one-shots: `nix develop --command bash -c '<command>'`. Don't fall back to `brew`-installed versions — they'll have wrong versions or be missing entirely.
- Workflows live in `Taskfile.yml`. Prefer `task <name>` over raw commands when one exists (e.g. `task tofu:plan`, `task login`, `task se`).
- `task login` gets AWS + OpenBao + SSH cert in one shot. Creds are cached: AWS ~12h, SSH cert ~16h, Bao TTL varies. Only re-run if a command fails with auth errors — check first with `task login:status`.

## Where to look

- **Hosts / IPs** → `ansible/inventory/hosts.yml` (resolves from `config/vm.yml` and `secrets/tf-outputs.json`). Don't hardcode IPs; reference them by name.
- **Lab overview** → `README.md` and `docs/` for context only. If docs and code disagree, **trust the code**.
- **Updating docs:** after every major task (migration, decommission, new component, topology change), sweep `docs/` for anything the change invalidated and update it. Only write what you've confirmed via code, command output, or direct user statement — no speculation. If you can't verify a section, leave it alone or flag it to the user.

## kubectl context

The host Talos cluster is `aether-k8s`; expected context is `admin@aether-k8s`. Before any `kubectl` / `helm` / `talosctl` work, verify:

```bash
kubectl config current-context       # expect: admin@aether-k8s
```

If it's wrong (or if `KUBECONFIG` is set to something outside this repo, e.g. by another project's direnv), fix it:

```bash
unset KUBECONFIG && task k8s:auth    # re-exports kubeconfig + talosconfig from tofu state
```

`task k8s:auth` **overwrites** `~/.kube/config` rather than merging. A reachable cluster is not the same as the right cluster — verify the context, not just connectivity.

## OpenTofu state locks — read this

State is remote (S3 + DynamoDB). If a `tofu` command fails with a lock error:

1. **Wait your turn.** Someone (or CI) is mid-apply. Poll every **30 seconds** until the lock clears.
2. **Never run `tofu force-unlock` on your own.** Even if you're confident the lock is stale, **ask the user first.** Force-unlocking a live apply corrupts state.
3. Only after the user confirms the lock is stuck (not just slow) should you run `task tofu:unlock -- <lock-id>`.

## Monitoring & observability

The monitoring stack VM (`monitoring-stack`, `10.0.2.3`, deployed by `ansible/playbooks/monitoring_stack/`) is a wealth of telemetry — use it before guessing. When debugging an issue ("is the cluster slow?", "did this deploy break something?", "what's eating the GPU?"), check here first.

What's collected:

- **Prometheus** — metrics. Scrapes Proxmox hosts (node-exporter + SMART), the PVE cluster API, PBS, Ceph (`ceph-exporter` per host on :9926), the OTel collector, and anything Proxmox VMs/k8s pods push via OTel. See `prometheus.yml` for the full target list.
- **Loki** — logs. VMs ship via the `vm_monitoring_agent` role; k8s ships via the cluster's OTel pipeline.
- **Tempo** — traces. Same OTel ingestion path. No public DNS — query via Grafana or Janus only.
- **ClickHouse** — Zeek + Suricata network/security data. Init scripts in `monitoring_stack/clickhouse/` define the schemas (raw ingest tables, typed tables, materialized views, aggregations) for both. Use this for network forensics, IDS investigation, or any "who talked to what" question.
- **Fleet** — osquery fleet manager. Live host introspection for the VMs (processes, packages, file integrity, etc.).
- **OTel collector** — central ingestion for metrics/logs/traces from VMs and the k8s cluster. Receivers on `:4317` (gRPC) and `:4318` (HTTP).

How to access:

| Service       | URL                                  | Notes                                                              |
| ------------- | ------------------------------------ | ------------------------------------------------------------------ |
| Grafana       | `https://grafana.home.shdr.ch`       | Primary entry point. SSO via Keycloak. All datasources pre-wired.  |
| Prometheus    | `https://prometheus.home.shdr.ch`    | Query API at `/api/v1/query` and `/api/v1/query_range`.            |
| Loki          | `https://loki.home.shdr.ch`          | LogQL via `/loki/api/v1/query_range`.                              |
| ClickHouse    | `https://clickhouse.home.shdr.ch`    | HTTP interface (port 8123). User `aether`; password in Bao.        |
| Fleet         | `https://fleet.home.shdr.ch`         | osquery management UI + API.                                       |
| OTel ingest   | `https://otel-metrics.home.shdr.ch`  | HTTP/gRPC receivers (for shipping, not querying).                  |

For browser investigation, hit `https://grafana.home.shdr.ch` — Keycloak SSO, datasources/dashboards pre-wired.

For programmatic access (CLI / scripts), use the Grafana service-account token stored as `grafana_sa_token` in `secrets/secrets.yml` (SOPS):

```bash
TOKEN=$(sops -d secrets/secrets.yml | yq '.grafana_sa_token')
curl -H "Authorization: Bearer $TOKEN" https://grafana.home.shdr.ch/api/datasources
# Proxy queries through Grafana to any datasource (Prometheus, Loki, Tempo, ClickHouse)
curl -H "Authorization: Bearer $TOKEN" "https://grafana.home.shdr.ch/api/datasources/proxy/uid/<ds-uid>/api/v1/query?query=up"
```

The token is **read-only** (Viewer role) — fine for querying datasources, listing dashboards, exporting panel data. Any mutation (creating dashboards, editing datasources, alert rules, users, orgs, etc.) must go through IaC (Ansible/Terraform), not the API. **Do not** use the `grafana_password` secret — that's the localhost basic-auth password the provisioning playbook uses on the VM (`127.0.0.1:3000`); it does not work against the public URL.

When you're not sure what's available, browse the provisioned dashboards in Grafana (`/dashboards`) — there's usually one for the layer you care about (Proxmox, Ceph, k8s, network, per-app).

## General etiquette

- Be a good neighbor. Other agents, humans, and CI share this repo's state. Wait your turn on locks; don't race.
- Destructive ops (force-push, `tofu destroy`, credential rotation, `kubectl delete` on shared resources) require explicit user confirmation every time.
- When a Taskfile target exists for what you're doing, use it — it bundles env setup (Bao token export, kubeconfig, etc.) you'll otherwise miss.
