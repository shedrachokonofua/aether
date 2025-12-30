# Patch Management Exploration

Exploration of centralized update visibility and controlled patch deployment.

## Goal

Create a unified workflow for managing container and system updates:

1. **Visibility** — Dashboard showing CVEs, available updates, and hygiene status
2. **Tiered policy** — Auto-update low-risk, notify for medium, manual for critical
3. **Controlled deployment** — One-click Ansible runs via web UI

## Current State

| Aspect           | Current          | Problem                                     |
| ---------------- | ---------------- | ------------------------------------------- |
| CVE awareness    | None             | Don't know when images have vulnerabilities |
| Update awareness | Manual checks    | Don't know when new versions exist          |
| Deployment       | CLI Ansible      | Have to SSH in, remember commands           |
| Audit trail      | Git history only | No record of who deployed what when         |

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Patch Management Stack                           │
│                                                                          │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐                           │
│   │  Trivy  │     │   WUD   │     │ Cockpit │                           │
│   │ (CVEs)  │     │(Images) │     │(OS pkgs)│                           │
│   └────┬────┘     └────┬────┘     └─────────┘                           │
│        │               │           (separate UI)                         │
│        ▼               ▼                                                 │
│   ┌─────────┐     ┌─────────┐                                           │
│   │/metrics │     │/metrics │                                           │
│   └────┬────┘     └────┬────┘                                           │
│        │               │                                                 │
│        └───────┬───────┘                                                 │
│                ▼                                                         │
│          ┌──────────┐                                                    │
│          │Prometheus│                                                    │
│          └────┬─────┘                                                    │
│               ▼                                                          │
│          ┌──────────┐         ┌───────────┐                             │
│          │ Grafana  │────────▶│ Semaphore │                             │
│          │Dashboard │  Link   │(Ansible)  │                             │
│          └──────────┘         └───────────┘                             │
│               │                     │                                    │
│               ▼                     ▼                                    │
│       "3 CRITICAL CVEs"     "Deploy grafana-stack"                      │
│       "5 container updates"        │                                    │
│                                    ▼                                    │
│                            Ansible playbook runs                        │
└─────────────────────────────────────────────────────────────────────────┘
```

## Components

### Trivy (CVE Scanning)

Scans container images for known vulnerabilities.

| Feature           | Use Case                              |
| ----------------- | ------------------------------------- |
| Image scanning    | Find CVEs in running containers       |
| Severity levels   | CRITICAL, HIGH, MEDIUM, LOW           |
| Prometheus export | Via `trivy-exporter` or scheduled job |
| Misconfiguration  | Scan Ansible/Terraform for issues     |
| Secret detection  | Find hardcoded credentials            |

**Centralized deployment:** Run Trivy on Monitoring Stack, no agents needed on each host.

```
WUD ──────► Image list ──────► Trivy ──────► Prometheus
(discovers)               (scans by name)
```

**How it works:**

1. WUD discovers images running across all Podman hosts
2. Scheduled job extracts image list from WUD API
3. Trivy scans each image by name (pulls from registry)
4. Results exported to Prometheus
5. Grafana displays CVEs

```bash
# Trivy scans images by name - no host access needed
trivy image docker.io/grafana/grafana:10.4.1
trivy image docker.io/prom/prometheus:2.51.0
```

**Metrics exposed:**

```
trivy_vulnerability_count{image="grafana/grafana", severity="CRITICAL"} 0
trivy_vulnerability_count{image="grafana/grafana", severity="HIGH"} 2
trivy_vulnerability_count{image="prom/prometheus", severity="CRITICAL"} 0
```

**Alternative:** Trivy Server mode for on-demand scanning via API.

### WUD (What's Up Docker)

Monitors running containers for available updates.

| Feature            | Use Case                              |
| ------------------ | ------------------------------------- |
| Registry polling   | Checks for newer image tags           |
| Prometheus metrics | Native `/metrics` endpoint            |
| Multi-registry     | Docker Hub, GHCR, private registries  |
| Podman support     | Works with Podman socket              |
| **Multi-host**     | Multiple watchers for different hosts |

**Multi-host configuration:** WUD supports multiple "watchers" — one per Podman host. Deploy WUD on Monitoring Stack, configure watchers pointing to Podman sockets on each VM via SSH tunnel or TCP.

```yaml
# Example watcher config for multiple hosts
WUD_WATCHER_LOCAL_SOCKET: /run/podman/podman.sock
WUD_WATCHER_GPU_HOST: tcp://gpu-workstation:2375
WUD_WATCHER_GATEWAY_HOST: tcp://home-gateway:2375
```

**Metrics exposed:**

```
wud_container_update_available{name="grafana"} 1
wud_container_current_tag{name="grafana"} "10.4.1"
wud_container_new_tag{name="grafana"} "10.4.2"
```

### Cockpit (OS Package Updates)

Already deployed via `cockpit_agent` role. Cockpit's Software Updates module provides:

| Feature          | Use Case                                    |
| ---------------- | ------------------------------------------- |
| Host switcher    | Centralized access to all hosts from one UI |
| Software Updates | Shows pending dnf/apt updates per host      |
| Security updates | Distinguishes security vs regular updates   |
| Apply from UI    | One-click update application                |
| Already deployed | No new tools needed                         |

**Scope:** OS packages (`dnf`, `apt`) — not containers. Complements WUD for full visibility.

**Alternative:** [PatchMon](https://github.com/PatchMon/PatchMon) if you want a dedicated dashboard with host groups, Proxmox LXC auto-enrollment, and REST API. But Cockpit already covers the basics.

### Grafana Dashboard

Unified view of security and update status.

| Panel              | Data Source | Shows                                |
| ------------------ | ----------- | ------------------------------------ |
| Critical CVEs      | Trivy       | Red alert, count, affected images    |
| High CVEs          | Trivy       | Yellow warning, count                |
| Container Updates  | WUD         | List of containers with new versions |
| Auto-Updated Today | Podman logs | What auto-updated recently           |
| Hygiene Score      | Calculated  | Overall status (green/yellow/red)    |

**Note:** OS package updates are visible via Cockpit (separate UI), not Grafana.

### Ansible Semaphore

Web UI for running Ansible playbooks.

| Feature          | Use Case                      |
| ---------------- | ----------------------------- |
| Templates        | Pre-configured playbook runs  |
| One-click deploy | Button to run update playbook |
| Audit log        | Who ran what, when, output    |
| RBAC             | Control who can deploy what   |
| Scheduling       | Optional scheduled runs       |

**Workflow:**

1. See "Grafana has CRITICAL CVE" in dashboard
2. Click link to Semaphore
3. Select "Deploy Monitoring Stack" template
4. Click Run
5. Watch output, verify success

## Tiered Update Policy

| Tier       | Policy               | Containers                                 | Rationale                              |
| ---------- | -------------------- | ------------------------------------------ | -------------------------------------- |
| **Auto**   | `podman auto-update` | Exporters, ntopng, Caddy, simple utilities | Stateless, low risk, restarts fine     |
| **Notify** | Dashboard + manual   | Grafana, Prometheus, Loki, Tempo, AdGuard  | Want to review release notes           |
| **Manual** | Dashboard + research | GitLab, Keycloak, OpenBao, databases       | Breaking changes, migrations, critical |

### Auto-Update Implementation

For Podman Quadlets in auto-update tier:

```ini
[Container]
Image=docker.io/prom/node-exporter:latest
AutoUpdate=registry

[Service]
Restart=always
```

Systemd timer runs `podman auto-update` daily:

```ini
# /etc/systemd/system/podman-auto-update.timer
[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

### Notify/Manual Tiers

Same visibility in dashboard, but no auto-action. Human decides when to deploy via Semaphore.

## VM and Host Updates

Not just containers — also need to track OS-level updates.

| Target        | Tool            | Policy                                 | Status          |
| ------------- | --------------- | -------------------------------------- | --------------- |
| Fedora VMs    | `dnf-automatic` | All updates auto, reboot when needed   | ✅ Already have |
| Proxmox hosts | `apt` scheduled | Notify only, manual maintenance window | ❌ Not yet      |
| VyOS          | Full VM rebuild | Manual, immutable infrastructure       | ✅ Already have |

### VyOS Upgrade Process

VyOS uses an immutable rebuild approach via `ansible/playbooks/home_router/`:

```
task provision:home:router
    │
    ├─► Provision Fedora packer VM
    ├─► Build VyOS cloud image from latest ISO
    ├─► Provision new router VM
    ├─► Apply network configuration
    └─► Destroy packer VM
```

**Upgrade workflow:** When a new VyOS release is available, run `task provision:home:router` to rebuild from the latest ISO. Config is stored in Ansible, so the new VM gets the same configuration applied automatically.

### Existing: DNF Automatic Role

Already configured via `ansible/roles/dnf/`:

| Variable                         | Default       | Description                            |
| -------------------------------- | ------------- | -------------------------------------- |
| `dnf_enable_automatic_updates`   | `true`        | Enable/disable automatic updates       |
| `dnf_automatic_update_type`      | `default`     | `default` (all) or `security` only     |
| `dnf_automatic_reboot`           | `when-needed` | `never`, `when-needed`, `when-changed` |
| `dnf_automatic_timer_oncalendar` | `05:00`       | Time to run updates (5am daily)        |

**Current behavior:** All Fedora VMs get automatic updates at 5am with auto-reboot when needed.

**Optional tuning:** For critical VMs, could set `dnf_automatic_update_type: security` to only auto-apply security patches, leaving feature updates for manual review.

## Deployment Plan

### Phase 1: Visibility

1. Deploy WUD container on Monitoring Stack
2. Configure to watch all Podman hosts
3. Add Prometheus scrape config
4. Create basic Grafana dashboard

### Phase 2: CVE Scanning

1. Deploy Trivy container on Monitoring Stack
2. Create scheduled job to get image list from WUD API
3. Scan images, export metrics to Prometheus
4. Add CVE panels to Grafana dashboard
5. Configure alerting for CRITICAL severity

### Phase 3: Semaphore

1. Deploy Semaphore container
2. Connect to GitLab repo (SSH key or token)
3. Create templates for each stack playbook
4. Add links from Grafana dashboard to Semaphore

### Phase 4: Auto-Update Tier

1. Identify containers safe for auto-update
2. Add `AutoUpdate=registry` to Quadlet files
3. Enable `podman-auto-update.timer` on hosts
4. Add "auto-updated today" panel to dashboard

### Phase 5: OS Package Visibility

1. ~~Configure `dnf-automatic` on Fedora VMs~~ ✅ Already done via `dnf` role
2. ~~Centralized host access~~ ✅ Already done via Cockpit host switcher
3. ~~Package update visibility~~ ✅ Already done via Cockpit Software Updates
4. Optional: Add Proxmox hosts to Cockpit host switcher if not already

## Grafana Dashboard

Dashboard built with Prometheus queries against WUD and Trivy metrics.

### Panels

| Panel                        | Type                    | Prometheus Query                                      |
| ---------------------------- | ----------------------- | ----------------------------------------------------- |
| Critical CVEs                | Stat (red threshold)    | `sum(trivy_vulnerability_count{severity="CRITICAL"})` |
| High CVEs                    | Stat (yellow threshold) | `sum(trivy_vulnerability_count{severity="HIGH"})`     |
| Updates Pending              | Stat                    | `count(wud_container_update_available == 1)`          |
| Containers Needing Attention | Table                   | Join WUD + Trivy metrics by image                     |
| Auto-Updated Today           | Logs panel              | Loki query for `podman auto-update` logs              |

### Links

"Deploy →" buttons use Grafana's data link feature to open Semaphore template URL with container name as parameter:

```
https://semaphore.home.shdr.ch/project/1/templates?filter=${__data.fields.container}
```

## Costs

| Item            | One-Time                   | Ongoing             |
| --------------- | -------------------------- | ------------------- |
| Time investment | ~8-12 hours                | ~30 min/week review |
| Compute         | Minimal (small containers) | Negligible          |
| Storage         | Trivy DB cache (~500MB)    | Negligible          |

## Decision Factors

### Pros

- Single pane of glass for security and updates
- Controlled deployment with audit trail
- Auto-update for low-risk, human control for critical
- Integrates with existing observability stack
- Reduces "I forgot to update X" risk

### Cons

- More moving parts (Trivy, WUD, Semaphore)
- Initial setup time
- Dashboard maintenance as stack evolves

## Open Questions

1. Should Semaphore run on Monitoring Stack or dedicated VM?
2. WUD vs Diun — WUD has better Prometheus, Diun is lighter
3. Trivy scan frequency — daily sufficient or more frequent for CVEs?
4. Include Proxmox host updates in same dashboard?

## Status

**Exploration phase.** Low complexity, high operational value.

## Related Documents

- `ceph.md` — Distributed storage plan
- `proxmox-ha.md` — HA for VMs
- `osquery.md` — SQL-based fleet querying (packages, processes, files, etc.)
- `../monitoring.md` — Existing observability stack
