# IDS Stack Exploration

Exploration of intrusion detection (network + host) and vulnerability scanning for internal security visibility.

## Goal

Extend security visibility beyond the public gateway to the internal network:

1. **Scanning** — Discover assets, open ports, vulnerabilities on internal network
2. **Visualization** — Network topology, traffic flows, asset inventory
3. **IDS** — Detect anomalies, threats, and policy violations on internal traffic

## Current State

| Aspect                 | Current                 | Gap                                          |
| ---------------------- | ----------------------- | -------------------------------------------- |
| Public IDS             | CrowdSec on AWS gateway | Only covers inbound public traffic           |
| Asset inventory        | Manual docs, Proxmox    | No network-wide discovery                    |
| Internal IDS           | None                    | Blind to east-west threats, lateral movement |
| Vulnerability scanning | None                    | Don't know what's exposed internally         |

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              IDS Stack                                       │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                        VyOS Router                                   │   │
│   │                                                                      │   │
│   │   eth1 (trunk) ──────► Port Mirror ──────► Suricata Span Port       │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         IDS Stack VM                                 │   │
│   │                                                                      │   │
│   │   ┌──────────┐     ┌──────────┐     ┌──────────┐                   │   │
│   │   │ Suricata │     │   Zeek   │     │  Wazuh   │                   │   │
│   │   │  (NIDS)  │     │(Protocol)│     │  (HIDS)  │                   │   │
│   │   └────┬─────┘     └────┬─────┘     └────┬─────┘                   │   │
│   │        │                │                │                          │   │
│   │        ▼                ▼                ▼                          │   │
│   │   ┌─────────────────────────────────────────┐                      │   │
│   │   │              OTEL Collector             │                      │   │
│   │   └─────────────────────────────────────────┘                      │   │
│   │                         │                                           │   │
│   └─────────────────────────┼───────────────────────────────────────────┘   │
│                             ▼                                                │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Monitoring Stack                                  │   │
│   │                                                                      │   │
│   │   Loki (logs) ◄─────── Suricata EVE JSON, Wazuh alerts             │   │
│   │   ClickHouse ◄──────── Zeek protocol logs (SQL analytics)         │   │
│   │   Prometheus ◄──────── Suricata metrics, Wazuh exporter            │   │
│   │   Grafana ◄──────────► Dashboards + Alerts                         │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### Suricata (Network IDS/IPS)

High-performance network threat detection. See [Suricata](https://suricata.io/).

| Feature                   | Use Case                                |
| ------------------------- | --------------------------------------- |
| Signature-based detection | Known attacks, CVE exploits, malware C2 |
| Protocol analysis         | HTTP, TLS, DNS, SMB, SSH anomalies      |
| EVE JSON logging          | Structured logs for Loki/Grafana        |
| Prometheus metrics        | Alert counts, traffic stats             |
| Rule updates              | ET Open, Abuse.ch, custom rules         |

**Deployment options:**

| Mode                | Pros                               | Cons                              |
| ------------------- | ---------------------------------- | --------------------------------- |
| VyOS integrated     | Inline IPS, no extra VM            | VyOS has limited Suricata support |
| Span port (passive) | Full visibility, no latency impact | IDS only, can't block             |
| Transparent bridge  | Inline IPS, dedicated VM           | Adds complexity                   |

**Recommendation:** Span port mode on a dedicated VM. Non-invasive, easy to start.

**VyOS mirror config:**

```bash
# Mirror all traffic from trunk port to security VM
set interfaces ethernet eth1 mirror-ingress eth2
set interfaces ethernet eth1 mirror-egress eth2
```

**What it detects:**

- Port scans and reconnaissance
- CVE exploit attempts
- Malware command & control
- DNS tunneling
- Unusual protocols (Tor, VPN inside VLAN)
- Policy violations (SMB from IoT, SSH brute force)

### Zeek (Network Protocol Analysis)

Deep protocol inspection and scripting. See [Zeek](https://zeek.org/).

| Feature            | Use Case                                |
| ------------------ | --------------------------------------- |
| Protocol parsing   | Extract metadata from 50+ protocols     |
| Connection logging | Who talked to whom, when, how much      |
| File extraction    | Capture transferred files for analysis  |
| Scripting          | Custom detection logic in Zeek language |
| Intelligence feeds | Correlate with threat intel             |

**Suricata vs Zeek:**

| Aspect   | Suricata                               | Zeek                                   |
| -------- | -------------------------------------- | -------------------------------------- |
| Strength | Signature matching, real-time alerting | Protocol analysis, metadata extraction |
| Output   | Alerts (bad things)                    | Logs (everything)                      |
| Use      | "Was this attack?"                     | "What happened on the network?"        |

**Recommendation:** Run both. Suricata for alerts, Zeek for context and forensics.

### Nuclei (Vulnerability Scanner)

Fast, template-based vulnerability scanner. See [Nuclei](https://github.com/projectdiscovery/nuclei).

| Feature           | Use Case                                     |
| ----------------- | -------------------------------------------- |
| Template library  | 8000+ community templates                    |
| CVE detection     | Find known vulnerabilities                   |
| Misconfigs        | Default creds, exposed panels, leaky headers |
| Scheduled scans   | Daily internal scans                         |
| CI/CD integration | Scan before deploy                           |

**Scan targets:**

```yaml
# Internal scan targets
- 10.0.2.0/24 # Infrastructure
- 10.0.3.0/24 # Services
```

**Example findings:**

- GitLab admin panel exposed without auth
- Default Grafana credentials
- Unpatched CVE in exposed service
- Debug endpoints enabled

**Deployment:** K8s CronJob in `infra` namespace (see `kubernetes.md`). Scales to zero between runs, results ship to Loki via K8s OTEL DaemonSet.

### NetBox (Network Source of Truth)

IPAM, DCIM, and network documentation. See [NetBox](https://netbox.dev/).

| Feature        | Use Case                        |
| -------------- | ------------------------------- |
| IPAM           | IP allocations, subnets, VLANs  |
| DCIM           | Racks, devices, cables, power   |
| Virtualization | VM inventory (Proxmox sync)     |
| Circuits       | WAN connections, ISP info       |
| Custom fields  | Tailored metadata               |
| API            | Automation, Ansible integration |

**Why NetBox:**

Current network docs are markdown tables. NetBox provides:

- Single source of truth for IP assignments
- Automatic conflict detection
- API for Ansible inventory
- Visual topology (with plugins)
- Change logging and audit trail

**Proxmox integration:** [netbox-proxmox-sync](https://github.com/netbox-community/netbox-proxmox-sync) keeps VM inventory in sync.

**Ansible integration:**

```yaml
# Dynamic inventory from NetBox
plugin: netbox.netbox.nb_inventory
api_endpoint: https://netbox.home.shdr.ch
```

### Wazuh (Host-Based IDS)

Host-level intrusion detection with centralized management. See [Wazuh](https://wazuh.com/).

| Feature                 | Use Case                             |
| ----------------------- | ------------------------------------ |
| File integrity (FIM)    | Detect unauthorized changes to files |
| Log analysis            | Parse syslog, auth.log, journald     |
| Rootkit detection       | Find hidden processes/files          |
| Vulnerability detection | Match installed packages to CVEs     |
| Active response         | Auto-block IPs, kill processes       |
| Compliance              | PCI-DSS, HIPAA, CIS benchmarks       |

**Architecture:**

```
┌─────────────────────────────────────────────────────────────┐
│                     Wazuh Manager                            │
│                    (on IDS Stack VM)                         │
│                                                              │
│   Receives events from all agents, correlates, alerts       │
└──────────────────────────┬──────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
   ┌───────────┐    ┌───────────┐    ┌───────────┐
   │  Agent    │    │  Agent    │    │  Agent    │
   │  GitLab   │    │  Dokploy  │    │  Gateway  │
   └───────────┘    └───────────┘    └───────────┘

   Watches: /etc, /bin, auth.log, processes, packages
```

**Suricata + Wazuh = Defense in Depth:**

| Scope        | Suricata                | Wazuh                     |
| ------------ | ----------------------- | ------------------------- |
| Network      | ✅ Sees all traffic     | ❌                        |
| Host         | ❌                      | ✅ Sees inside each VM    |
| Catches      | Network attacks, C2     | File tampering, rootkits  |
| Lateral move | ✅ Sees traffic between | ✅ Sees process execution |

**Example: Attacker compromises GitLab:**

1. Exploit arrives over network → **Suricata alerts**
2. Attacker downloads tools → **Zeek logs the transfer**
3. Attacker modifies `/etc/crontab` → **Wazuh alerts (FIM)**
4. Attacker creates backdoor user → **Wazuh alerts (auth.log)**
5. Attacker scans internal network → **Suricata alerts**

**Agent deployment:** Add to `vm_monitoring_agent` role alongside OTEL Collector:

```yaml
# Example vars
wazuh_manager_address: "10.0.2.x" # Network Security Stack IP
wazuh_agent_groups: ["linux", "fedora"]
```

## Integration with Existing Stack

### Log Routing

OTEL Collector routes logs based on source:

| Source   | Destination | Reason                                            |
| -------- | ----------- | ------------------------------------------------- |
| Suricata | Loki        | Alert-focused, works well with LogQL              |
| Zeek     | ClickHouse  | High-volume protocol logs, SQL analytics at scale |
| Wazuh    | Loki        | Host alerts alongside other system logs           |

**Zeek → ClickHouse:** Uses routing connector in OTEL config to detect `log.source=zeek` resource attribute and route to ClickHouse exporter. Typed tables + materialized views auto-transform raw JSON into queryable columns.

**Suricata → Loki:** EVE JSON logs ship directly to Loki:

```yaml
# otel-collector config
receivers:
  filelog:
    include: [/var/log/suricata/eve.json]
    operators:
      - type: json_parser

exporters:
  otlphttp/loki:
    endpoint: http://localhost:3100/otlp
```

### Grafana Dashboards

| Dashboard       | Data Source            | Shows                                     |
| --------------- | ---------------------- | ----------------------------------------- |
| IDS Monitoring  | Loki + ClickHouse      | Combined Suricata alerts + Zeek analytics |
| Suricata Alerts | Loki                   | Alert timeline, severity, signatures      |
| Zeek Analytics  | ClickHouse             | Connections, DNS, HTTP, SSL, SSH, files   |
| Threat Intel    | Suricata + intel feeds | Matched IOCs, blocked IPs                 |
| Scan Results    | Nuclei                 | Vulnerabilities by host, severity         |

### Alerting

Route high-severity Suricata alerts to ntfy:

```yaml
# Grafana alert rule
- alert: SuricataHighSeverityAlert
  expr: count_over_time({job="suricata"} |= "severity\":1" [5m]) > 0
  labels:
    severity: critical
  annotations:
    summary: "High severity IDS alert detected"
```

### Tool Correlation

Each tool answers different questions:

| Tool     | Question                                      | Data Store |
| -------- | --------------------------------------------- | ---------- |
| Zeek     | "Who's talking to whom? What protocols/data?" | ClickHouse |
| Suricata | "Is that traffic malicious?"                  | Loki       |
| Wazuh    | "What's happening on the hosts themselves?"   | Loki       |

## Deployment Plan

### Phase 1: IDS Stack VM ✅

1. ✅ Create IDS Stack VM (Infrastructure VLAN, 4GB RAM)
2. ✅ Configure VyOS port mirror to span port
3. ✅ Install Suricata with ET Open rules (on VyOS router)
4. ✅ Install Zeek (quadlet container)
5. ✅ Install Wazuh Manager (quadlet container)
6. ✅ Configure EVE JSON logging + Zeek logs + Wazuh alerts
7. ✅ Ship logs via OTEL (Zeek/Suricata → ClickHouse, Wazuh → Loki)
8. ✅ Create Grafana dashboards (IDS Monitoring)
9. ⏳ Configure alerts for severity 1-2

### Phase 2: Wazuh Agents

1. Add Wazuh agent tasks to `vm_monitoring_agent` role
2. Deploy agents to all VMs
3. Configure FIM paths (`/etc`, `/bin`, `/usr/bin`)
4. Add host security panels to Grafana

### Phase 3: Vulnerability Scanning (K8s)

Nuclei runs on K8s as a CronJob (no span port requirement, scales to zero):

1. Create Nuclei CronJob in `infra` namespace
2. Configure scan target list (internal subnets)
3. Schedule daily scans (midnight)
4. Results ship to Loki via K8s OTEL DaemonSet
5. Add scan results panel to Grafana dashboard
6. Alert on new high/critical findings

See `kubernetes.md` for K8s deployment details.

### Phase 4: Tuning + Scale

1. Monitor IDS Stack resource usage
2. Bump RAM to 6-8GB if hitting limits
3. Tune Suricata rules (disable noisy/irrelevant signatures)
4. Tune Wazuh FIM paths based on false positives
5. Add custom Zeek scripts if needed

## Lab Integration

### Proposed VM Allocation

| Name      | Host   | Type    | RAM | Storage | Storage Location | vCPU | On By Default | Notes                                  | Status   |
| --------- | ------ | ------- | --- | ------- | ---------------- | ---- | ------------- | -------------------------------------- | -------- |
| IDS Stack | Oracle | VM      | 4GB | 128GB   | Node             | 4    | Yes           | Suricata + Zeek + Wazuh Manager + OTEL | DEPLOYED |
| Nuclei    | K8s    | CronJob | —   | —       | —                | —    | —             | Scales to zero between scans           | PLANNED  |

**Oracle current allocation (16GB host):**

| VM            | RAM     |
| ------------- | ------- |
| Router        | 2GB     |
| Gateway Stack | 2GB     |
| Keycloak      | 2GB     |
| step-ca       | 512MB   |
| OpenBao       | 512MB   |
| AdGuard       | 1GB     |
| **Current**   | **8GB** |

**Oracle after IDS Stack:**

| VM           | RAM         |
| ------------ | ----------- |
| (existing)   | 8GB         |
| IDS Stack    | 4GB         |
| **Total**    | **12GB** ✅ |
| **Headroom** | **4GB** 👍  |

**Note:** 4GB is tight for Suricata + Zeek + Wazuh. Monitor usage and bump to 6-8GB if needed.

### Host Placement Rationale

**IDS Stack → Oracle:**

- Router VM is on Oracle — mirrored traffic stays on internal bridge (no physical network)
- Internal vmbr = memory-to-memory, effectively unlimited bandwidth
- No risk of saturating physical NICs during bulk transfers
- Infrastructure VLAN (V2) placement alongside core services
- All IDS (network + host) in one place
- Oracle VMs already optimized — 8GB headroom available

### Network Configuration

IDS Stack needs a dedicated NIC for span traffic:

```
┌───────────────────────────────────────────────────────────────────┐
│                           Oracle Host                              │
│                                                                    │
│   ┌──────────┐         ┌──────────────────────────┐               │
│   │  Router  │         │        IDS Stack         │               │
│   │  (VyOS)  │         │                          │               │
│   │          │         │  eth0: 10.0.2.x          │◄── Management │
│   │   eth1 ──┼─mirror─►│  eth1: span (promisc)    │◄── Mirrored   │
│   │  (trunk) │         │                          │               │
│   └──────────┘         └──────────────────────────┘               │
│         │                                                          │
│         └──── vmbr1 (trunk to physical switch) ───────────────────┘
└───────────────────────────────────────────────────────────────────┘
```

**VyOS config:**

```bash
# Mirror trunk traffic to IDS Stack's span interface
set interfaces ethernet eth1 mirror ingress eth2
set interfaces ethernet eth1 mirror egress eth2
```

**Proxmox VM config:**

```bash
# IDS Stack - eth1 (span port)
# Attach to same bridge as router trunk, promiscuous mode
net1: virtio,bridge=vmbr1,firewall=0
```

### Resource Impact

| Metric  | Current | After | Net Change |
| ------- | ------- | ----- | ---------- |
| RAM     | —       | —     | +4GB       |
| vCPU    | —       | —     | +4         |
| Storage | —       | —     | +128GB     |

**Wazuh agents:** ~50MB RAM each, negligible CPU. Deployed via `vm_monitoring_agent` role.

### Integration Points

| Component     | Integrates With  | How                                        |
| ------------- | ---------------- | ------------------------------------------ |
| IDS Stack     | Router           | Receives mirrored traffic (internal vmbr)  |
| IDS Stack     | Monitoring Stack | OTEL Collector → ClickHouse + Loki         |
| Wazuh Manager | All VMs          | Agents connect to manager (1514) — pending |
| Wazuh Manager | Grafana          | Alerts via Loki (JSON logs)                |

## Maintenance

| Component    | Location    | Ongoing                                  |
| ------------ | ----------- | ---------------------------------------- |
| Suricata     | VyOS Router | Rule updates (automated via cron)        |
| Zeek         | IDS Stack   | Minimal (container auto-updates)         |
| Wazuh        | IDS Stack   | Rule tuning, FIM path adjustments        |
| Wazuh agents | VMs         | Part of `vm_monitoring_agent` role (TBD) |
| Nuclei       | K8s         | Template updates (automated)             |
| Dashboards   | Grafana     | Evolves with stack                       |

## Decision Factors

### Pros

- Network-wide threat visibility (not just public gateway)
- Detect lateral movement, internal compromise
- Asset discovery and vulnerability awareness
- Single source of truth for network documentation
- Integrates cleanly with existing Grafana/Loki stack

### Cons

- Span port requires VyOS config change
- More logs = more storage (Loki retention)
- False positives require tuning (especially Suricata rules)
- Wazuh agents on every VM (but lightweight, ~50MB RAM)

### Priority Recommendation

| Priority | Component | Location | Rationale                                       |
| -------- | --------- | -------- | ----------------------------------------------- |
| High     | Suricata  | VM       | Biggest gap — no internal network IDS           |
| High     | Zeek      | VM       | Protocol analysis + forensic depth              |
| High     | Wazuh     | VM       | Catches what network IDS can't — host tampering |
| High     | Nuclei    | K8s      | Easy win — scales to zero, no span port needed  |
| Skip     | NetBox    | —        | Overkill — current markdown docs work fine      |

**Why Nuclei on K8s:** Unlike Suricata/Zeek (which need span port traffic from VyOS on the same host) and Wazuh (which must survive K8s compromise), Nuclei is a scheduled scanner with no network topology constraints. CronJob scales to zero between scans.

## Open Questions

1. VyOS span port — mirror all VLANs or selective (exclude Guest/IoT for noise)?
2. Suricata rule sets — ET Open sufficient or add Abuse.ch, custom rules?
3. Nuclei scan scope — all internal or just Infrastructure + Services VLANs?
4. Log retention — how long to keep IDS logs in Loki? (Currently 90 days)
5. Wazuh agents — deploy to all VMs or start with critical services only?
6. Wazuh FIM paths — which directories to monitor beyond defaults?
7. Wazuh dashboard — use native (Kibana-based) or Grafana only?

## Alternatives Considered

### Security Onion

Full-stack security monitoring (Suricata + Zeek + Elastic + Kibana).

| Pros                 | Cons                                         |
| -------------------- | -------------------------------------------- |
| All-in-one solution  | Heavy (16GB+ RAM)                            |
| Pre-built dashboards | Doesn't integrate with existing Grafana/Loki |
| Community support    | Another stack to learn                       |

**Verdict:** Too heavy, prefer à la carte integration with existing stack.

### Arkime (Moloch)

Full packet capture and indexing.

| Pros                     | Cons                         |
| ------------------------ | ---------------------------- |
| Complete traffic history | Massive storage requirements |
| Powerful forensics       | Overkill for homelab         |

**Verdict:** Skip unless you need packet-level forensics.

### OpenVAS/Greenbone

Enterprise vulnerability scanner.

| Pros                | Cons                           |
| ------------------- | ------------------------------ |
| Comprehensive scans | Heavy, slow, complex           |
| Compliance reports  | Overkill for internal scanning |

**Verdict:** Nuclei is faster, lighter, and sufficient.

## Status

**Phase 1 complete.** IDS Stack VM deployed on Oracle with:

- **Suricata** — Running on VyOS router, EVE JSON to ClickHouse
- **Zeek** — Container on IDS Stack, protocol logs to ClickHouse
- **Wazuh Manager** — Container on IDS Stack, alerts to Loki

Logs route via OTEL: Zeek/Suricata → ClickHouse, Wazuh → Loki. IDS Monitoring dashboard provides unified view. See [ClickHouse exploration](clickhouse.md) for implementation details.

**Remaining:**

- Phase 2: Wazuh agents to VMs (not yet deployed)
- Phase 3: Nuclei on K8s
- Phase 4: Tuning + scale

## Related Documents

- `kubernetes.md` — Nuclei runs as K8s CronJob in `infra` namespace
- `osquery.md` — Fleet server on Monitoring Stack, SQL-based fleet querying
- `../virtual-machines.md` — VM allocation and resource usage
- `../networking.md` — Current network architecture
- `../monitoring.md` — Existing observability stack
- `patch-management.md` — Vulnerability management
