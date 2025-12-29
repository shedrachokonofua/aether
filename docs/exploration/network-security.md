# Network Security Exploration

Exploration of network scanning, visualization, and intrusion detection for internal network visibility.

## Goal

Extend security visibility beyond the public gateway to the internal network:

1. **Scanning** — Discover assets, open ports, vulnerabilities on internal network
2. **Visualization** — Network topology, traffic flows, asset inventory
3. **IDS** — Detect anomalies, threats, and policy violations on internal traffic

## Current State

| Aspect                 | Current                 | Gap                                          |
| ---------------------- | ----------------------- | -------------------------------------------- |
| Public IDS             | CrowdSec on AWS gateway | Only covers inbound public traffic           |
| Traffic analysis       | ntopng (sFlow/NetFlow)  | Volume/flow visibility, not deep inspection  |
| Asset inventory        | Manual docs, Proxmox    | No network-wide discovery                    |
| Internal IDS           | None                    | Blind to east-west threats, lateral movement |
| Vulnerability scanning | None                    | Don't know what's exposed internally         |

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Network Security Stack                                 │
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
│   │                    Network Security Stack                           │   │
│   │                                                                      │   │
│   │   ┌──────────┐     ┌──────────┐     ┌──────────┐                   │   │
│   │   │ Suricata │     │   Zeek   │     │  Nuclei  │                   │   │
│   │   │  (IDS)   │     │(Protocol)│     │ (Scanner)│                   │   │
│   │   └────┬─────┘     └────┬─────┘     └────┬─────┘                   │   │
│   │        │                │                │                          │   │
│   │        ▼                ▼                ▼                          │   │
│   │   ┌─────────────────────────────────────────┐                      │   │
│   │   │              Filebeat / OTEL            │                      │   │
│   │   └─────────────────────────────────────────┘                      │   │
│   │                         │                                           │   │
│   └─────────────────────────┼───────────────────────────────────────────┘   │
│                             ▼                                                │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Monitoring Stack                                  │   │
│   │                                                                      │   │
│   │   Loki (logs) ◄─────── Suricata EVE JSON                           │   │
│   │   Prometheus ◄──────── Suricata metrics                            │   │
│   │   Grafana ◄──────────► Dashboards + Alerts                         │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                       NetBox (IPAM/DCIM)                             │   │
│   │                                                                      │   │
│   │   Network topology · IP allocations · Device inventory              │   │
│   │   Cables · VLANs · Rack layouts · Documentation                     │   │
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
| Scheduled scans   | Weekly/monthly internal scans                |
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

**Deployment:** Scheduled systemd timer, results to Loki or ntfy alerts.

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
│                (on Network Security Stack)                   │
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

### Logging to Loki

Suricata EVE JSON logs ship directly to Loki:

```yaml
# otel-collector config
receivers:
  filelog:
    include: [/var/log/suricata/eve.json]
    operators:
      - type: json_parser

exporters:
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
```

### Grafana Dashboards

| Dashboard       | Data                   | Shows                                |
| --------------- | ---------------------- | ------------------------------------ |
| Suricata Alerts | Loki                   | Alert timeline, severity, signatures |
| Network Flows   | Zeek logs              | Top talkers, protocols, connections  |
| Threat Intel    | Suricata + intel feeds | Matched IOCs, blocked IPs            |
| Scan Results    | Nuclei                 | Vulnerabilities by host, severity    |

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

### Correlating with ntopng

ntopng shows traffic volume, Suricata shows threats:

| Tool     | Question                                         |
| -------- | ------------------------------------------------ |
| ntopng   | "Who's using the most bandwidth?"                |
| Suricata | "Is that traffic malicious?"                     |
| Zeek     | "What protocols and data are being transferred?" |

## Deployment Plan

### Phase 1: Network Security Stack VM

1. Create Network Security Stack VM (Infrastructure VLAN)
2. Configure VyOS port mirror to span port
3. Install Suricata with ET Open rules
4. Configure EVE JSON logging
5. Ship logs to Loki via OTEL Collector
6. Create Grafana dashboard
7. Configure alerts for severity 1-2

### Phase 2: Wazuh (Host IDS)

1. Add Wazuh Manager to Monitoring Stack (bump RAM 8GB → 10GB)
2. Configure manager (agent groups, rules, decoders)
3. Add Wazuh agent tasks to `vm_monitoring_agent` role
4. Deploy agents to all VMs
5. Configure FIM paths (`/etc`, `/bin`, `/usr/bin`)
6. Ship alerts to Loki or use Wazuh Prometheus exporter
7. Add host security panels to Grafana

### Phase 3: Vulnerability Scanning

1. Install Nuclei on Network Security Stack VM
2. Create scan target list (internal subnets)
3. Create systemd timer for weekly scans
4. Ship results to Loki
5. Add scan results panel to dashboard

### Phase 4: Deep Protocol Analysis (Optional)

1. Add Zeek to Network Security Stack (may need RAM bump) or deploy on Niobe
2. Configure to parse alongside Suricata
3. Ship conn.log, dns.log, http.log to Loki
4. Add forensics queries to Grafana

**Note:** 6GB is tight for Suricata + Wazuh + Zeek. Add Zeek later if needed, or run it on Niobe for forensics (accepts the network hop tradeoff for non-realtime analysis).

## Lab Integration

### Proposed VM Allocation

| Name                   | Host   | Type | RAM | Storage | Storage Location | vCPU | On By Default | Notes                              | Status  |
| ---------------------- | ------ | ---- | --- | ------- | ---------------- | ---- | ------------- | ---------------------------------- | ------- |
| Network Security Stack | Oracle | VM   | 4GB | 128GB   | Node             | 4    | Yes           | Suricata, Nuclei, OTEL             | PLANNED |
| (Wazuh Manager)        | Niobe  | —    | —   | —       | —                | —    | —             | Added to existing Monitoring Stack | PLANNED |

**Requires downsizing existing Oracle VMs:**

| VM              | Current | New   | Actual Used | Savings |
| --------------- | ------- | ----- | ----------- | ------- |
| Router          | 4GB     | 2GB   | 1.6GB       | 2GB     |
| step-ca         | 1GB     | 512MB | 0.2GB       | 512MB   |
| OpenBao         | 2GB     | 512MB | 0.09GB      | 1.5GB   |
| **Total freed** |         |       |             | **4GB** |

**Oracle after changes (16GB host):**

| VM                     | RAM         |
| ---------------------- | ----------- |
| Router                 | 2GB         |
| Gateway Stack          | 4GB         |
| Keycloak               | 2GB         |
| step-ca                | 512MB       |
| OpenBao                | 512MB       |
| AdGuard (planned)      | 1GB         |
| Network Security Stack | 4GB         |
| **Total**              | **14GB** ✅ |
| **Headroom**           | **2GB** 👍  |

**Monitoring Stack (Niobe) addition:**

| Component     | RAM Added |
| ------------- | --------- |
| Wazuh Manager | +2GB      |

Monitoring Stack: 8GB → 10GB (Niobe has 64GB, plenty of room)

### Host Placement Rationale

**Network Security Stack → Oracle:**

- Router VM is on Oracle — mirrored traffic stays on internal bridge (no physical network)
- Internal vmbr = memory-to-memory, effectively unlimited bandwidth
- No risk of saturating physical NICs during bulk transfers
- Infrastructure VLAN (V2) placement alongside core services
- Wazuh Manager centrally located for agent connections
- Requires downsizing Router (4→2GB), Gateway (4→3GB), OpenBao (2→1GB) to fit

### Network Configuration

Network Security Stack needs a dedicated NIC for span traffic:

```
┌───────────────────────────────────────────────────────────────────┐
│                           Oracle Host                              │
│                                                                    │
│   ┌──────────┐         ┌──────────────────────────┐               │
│   │  Router  │         │  Network Security Stack  │               │
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
# Mirror trunk traffic to Network Security Stack's span interface
set interfaces ethernet eth1 mirror ingress eth2
set interfaces ethernet eth1 mirror egress eth2
```

**Proxmox VM config:**

```bash
# Network Security Stack - eth1 (span port)
# Attach to same bridge as router trunk, promiscuous mode
net1: virtio,bridge=vmbr1,firewall=0
```

### Resource Impact

| Metric  | Current | After  | Net Change |
| ------- | ------- | ------ | ---------- |
| RAM     | 194GB   | 196GB  | +2GB       |
| vCPU    | 137     | 141    | +4         |
| Storage | ~3.5TB  | ~3.6TB | +128GB     |

RAM breakdown: Security Stack +4GB, Wazuh +2GB to Monitoring Stack, downsizing saves 4GB.

**Wazuh agents:** ~50MB RAM each, negligible CPU. Deployed via `vm_monitoring_agent` role.

### Integration Points

| Component              | Integrates With  | How                                       |
| ---------------------- | ---------------- | ----------------------------------------- |
| Network Security Stack | Router           | Receives mirrored traffic (internal vmbr) |
| Network Security Stack | Monitoring Stack | OTEL Collector → Loki, Prometheus         |
| Wazuh Manager          | Monitoring Stack | Co-located, shared Grafana                |
| Wazuh Manager          | All VMs          | Agents connect to manager (1514)          |
| Wazuh Manager          | Grafana          | Wazuh exporter → Prometheus               |

## Maintenance

| Component    | Ongoing                            |
| ------------ | ---------------------------------- |
| Suricata     | Rule updates (automated via cron)  |
| Wazuh        | Rule tuning, FIM path adjustments  |
| Wazuh agents | Part of `vm_monitoring_agent` role |
| Nuclei       | Template updates (automated)       |
| Zeek         | Minimal                            |
| Dashboards   | Evolves with stack                 |

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

| Priority | Component | Rationale                                       |
| -------- | --------- | ----------------------------------------------- |
| High     | Suricata  | Biggest gap — no internal network IDS           |
| High     | Wazuh     | Catches what network IDS can't — host tampering |
| High     | Nuclei    | Easy win — know what's exposed                  |
| Medium   | Zeek      | Adds forensic depth, run alongside Suricata     |
| Skip     | NetBox    | Overkill — current markdown docs work fine      |

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

**Exploration phase.** Suricata (network) + Wazuh (host) provide defense in depth. Nuclei adds proactive scanning. Start with Phases 1-3.

## Related Documents

- `../virtual-machines.md` — VM allocation and resource usage
- `../networking.md` — Current network architecture
- `../monitoring.md` — Existing observability stack
- `osquery.md` — Host-level visibility (complements network IDS)
- `patch-management.md` — Vulnerability management
