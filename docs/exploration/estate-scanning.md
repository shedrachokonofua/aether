# Estate Discovery and Vulnerability Scanning

Plan for active asset discovery, service fingerprinting, and vulnerability validation across the Aether home, cloud, and routed-site estate.

**Status (honest, 2026-07-14):** Inventory + curated daily L7 + Kestra E2E are
live. UniFi pinned to `version-10.1.89` (CVE-2026-22557 closed-loop resolved);
ceph-csi nodeplugin `httpMetrics` off; insert-time accepted findings +
resolve-on-absence; `coverage_ratio` is attempt completeness. Daily schedule
`15 5 * * *` America/New_York enabled on `estate-scan-home`. SSH host-key pin
still deferred (plugin lacks `knownHosts`). Weekly broad catalogs and cloud/
VLAN expansion remain later. Supersedes the Kubernetes Nuclei placement proposed
in `network-security.md`.

Guest: neo LXC `1036` / `10.0.2.13`. ClickHouse `estate_scan`, Grafana
`uid: estate-scan`, Kestra `aether.estate/estate-scan-home` managed by
`task tofu:kestra-flows:apply`.

## Goals

- Find undeclared hosts and services, including devices that ignore ICMP.
- Detect new, changed, and unexpectedly public listeners quickly.
- Validate confirmed services with safe, reproducible Nuclei templates.
- Cover home VLANs, the Gigahub network, AWS, GCP, and routed WireGuard identities.
- Preserve passive IDS reliability while active scans run.
- Produce stateful asset, service, and finding history rather than repeated raw alerts.
- Keep the design small enough to operate without Greenbone/OpenVAS, NetBox, or a commercial attack-surface platform.

## Non-goals

- Automatic exploitation or remediation.
- DoS, fuzzing, brute force, credential stuffing, or indiscriminate authenticated scanning.
- Full 65,535-port UDP sweeps.
- Scanning networks or systems Aether does not own or have permission to test.
- Replacing Trivy, Wazuh, Zeek, Suricata, or cloud-native posture data.
- Preserving Fleet as a dependency; Fleet is being retired.

## Decisions

1. Run active scanning from a dedicated guest on `neo`, not from Kubernetes and not inside `intrusion-detection-stack`.
2. Prefer an unprivileged LXC sized at 2 vCPU, 4 GiB RAM, 1 GiB swap, and 32 GiB disk.
3. Give the scanner a dedicated, inventory-managed address on VLAN 2. Do not reuse `10.0.2.7`, the IDS-stack identity.
4. Keep the LXC unprivileged. If reliable SYN scanning requires broad container privilege, use a small VM on `neo` instead of a privileged LXC.
5. Keep Oracle at 16 GiB for this project. A future Oracle RAM upgrade and control-plane-only Talos VM are separate work.
6. Use continuous passive evidence plus layered active scans; do not make the monthly blind sweep the only discovery mechanism.
7. Scan public and private cloud paths independently.
8. Pin scanner binaries and Nuclei templates. Never update templates implicitly immediately before a production scan.
9. Store structured scan state in ClickHouse; use Loki only for scanner execution logs.
10. Aggregate repetitive failed authorized probes rather than duplicating each attempt into general Zeek and Suricata flow storage.
11. Retain successful, unexpected, off-schedule, and out-of-scope scanner traffic as security evidence.
12. Keep remediation human-reviewed and IaC-driven.
13. Use Kestra as the orchestration control plane and the scanner guest as the network-execution data plane.
14. Keep Kestra unprivileged: it selects reviewed scan profiles but cannot supply arbitrary commands, targets, rates, or templates.
15. Make Kestra the single schedule authority. Scanner systemd units isolate accepted executions but do not carry duplicate calendar schedules.
16. Ensure a scan accepted by the guest continues if the Kestra connection or Kubernetes control plane is interrupted.

## Placement

### Scanner guest

| Property | Decision |
| --- | --- |
| Proxmox host | `neo` |
| Guest type | Unprivileged LXC; fall back to a VM if narrow raw-socket access is not viable |
| CPU | 2 vCPU initially |
| Memory | 4 GiB initially |
| Swap | 1 GiB |
| Disk | 32 GiB |
| Network | VLAN 2, dedicated address selected through authoritative inventory |
| Inbound services | Administrative SSH plus a separate forced-command SSH dispatch identity, both restricted to their expected source paths |
| Privileges | No Kubernetes administration, cloud administration, application secrets, or general OpenBao administration |

A live read-only snapshot on 2026-07-12 showed `neo` at approximately 60.5% memory use and below 61.6% over the preceding seven days, with roughly 47–49 GiB available. Oracle was approximately 78% utilized, had about 3 GiB of swap allocated, and its declared long-lived guest memory already totaled its physical 16 GiB. These figures justify the initial placement but are not capacity guarantees; deployment must recheck live headroom.

### Why not the IDS VM

- Active scanner load cannot starve Zeek or Wazuh.
- Scanner crashes and template failures remain isolated from passive collection.
- Scanner package upgrades do not modify the IDS NixOS closure.
- The dedicated guest naturally provides a distinct source identity.
- The scanner can be rebuilt without interrupting evidence collection.

The scanner remains logically part of the security stack. Its routed traffic traverses VyOS, is observed by the IDS pipeline, and is correlated with its structured results in ClickHouse.

## Coverage

### Home and management networks

| Network | Role | Coverage profile |
| --- | --- | --- |
| `10.0.2.0/24` | Infrastructure | Full |
| `10.0.3.0/24` | Services | Full |
| `10.0.4.0/24` | Personal | Full, moderate per-host rate |
| `10.0.5.0/24` | Media | Full, moderate per-host rate |
| `10.0.6.0/24` | IoT | Full discovery, conservative service validation |
| `10.0.7.0/24` | Guest | Full discovery, conservative service validation |
| `192.168.2.0/24` | Gigahub and management | Full discovery with the lowest embedded-device rate |

The seven `/24`s contain 1,778 usable addresses. A blind all-address/all-TCP-port pass is approximately 116.5 million probes. That is acceptable as an occasional discovery control, not as the routine fast loop.

### AWS

Authoritative declarations currently identify one Lightsail instance:

- `aether-public-gateway`, Amazon Linux 2023.
- Static public address from `aws_lightsail_static_ip.public_gateway_static_ip`.
- Declared public listeners: TCP 22, TCP 443, UDP 51820.
- Routed WireGuard site identity: `10.1.0.10`.
- WireGuard fabric identity: `10.254.0.1`.

Scan separately:

- direct public IPv4 and IPv6, when assigned;
- public DNS and HTTPS routes;
- private `10.1.0.10` over WireGuard.

Any public listener outside the declared surface is a high-priority finding until reconciled with IaC.

### GCP

Authoritative declarations currently identify one Compute Engine instance:

- `aether-uptime-monitor`, Debian 12.
- Ephemeral public IPv4; resolve it from current state/API before every scan.
- Cloudflare Tunnel application routes.
- Routed WireGuard site identity: `10.2.0.10`.
- WireGuard fabric identity: `10.254.0.3`.

Scan separately:

- current public IPv4 and IPv6, when assigned;
- tunnel and public DNS hostnames;
- private `10.2.0.10` over WireGuard.

Keep GCP OS Config enabled as independent package, patch, and vulnerability evidence.

### Kubernetes

Do not scan ephemeral pod CIDRs indiscriminately. Cover Kubernetes through stable surfaces:

- Talos node addresses and declared control-plane ports;
- Cilium Gateway and LoadBalancer VIPs;
- Gateway API and HTTPRoute hostnames;
- declared NodePorts, if present;
- internal, tunnel, LAN-VIP, and public application hostnames.

Trivy remains responsible for container CVEs, configuration audits, RBAC assessment, secret exposure, infrastructure assessment, and cluster compliance.

### Tailscale and IPv6

- Enumerate owned Tailscale nodes from authoritative inventory; never sweep `100.64.0.0/10`.
- Build IPv6 targets from DNS AAAA records, cloud APIs, router neighbor data, Kubernetes, Tailscale, and passive observations. Do not brute-force IPv6 prefixes.

## Target sources

Build the scan inventory as a union of:

- `config/vm.yml`;
- `ansible/inventory/hosts.yml`;
- Kubernetes namespace contracts, Services, Gateways, HTTPRoutes, and LoadBalancers;
- VyOS VLAN and route declarations;
- home and public Caddy routes;
- Cloudflare DNS and tunnel declarations;
- AWS and GCP state/API inventory;
- Tailscale declarations;
- DHCP leases and router neighbor data;
- Zeek DNS, TLS, and connection observations;
- results from prior active scans.

Every target record must preserve its provenance: declared, passive, discovered, cloud API, Kubernetes, DNS, or operator-supplied.

An address enters the weekly full-port set when it is declared, responds to discovery, appears in neighbor/DHCP data, is observed passively, or was seen during the previous 30 days. ICMP failure alone never marks an address dead.

## Toolchain

```text
authoritative inventory + passive observations
    -> host and TCP discovery (Naabu)
    -> targeted UDP and service confirmation (Nmap)
    -> HTTP/TLS normalization (httpx)
    -> safe vulnerability validation (Nuclei)
    -> normalized ClickHouse state
    -> Grafana dashboards and alerts
```

Use targeted Nmap service detection only on open or changed listeners. Do not run expensive version detection against every closed port.

## Orchestration boundary

Kestra orchestrates the workflows from Kubernetes; the dedicated guest on `neo`
performs all network operations. This separation keeps raw sockets, broad routed
egress, and the stable scanner source identity outside Kubernetes while retaining
Kestra's schedules, retries, execution history, and change-triggered workflows.

```text
Kestra schedule, manual run, or change trigger
    -> snapshot authoritative targets
    -> dispatch discovery shards by approved target group
    -> validate coverage, merge results, and diff prior services
    -> if new or changed listeners: fingerprint those listeners
    -> branch by confirmed protocol into safe validation profiles
    -> finalize run lineage, coverage, and result state
    -> Grafana findings and coverage alerts
```

### Kestra responsibilities

- create the run ID;
- select an approved scan profile;
- enforce workflow-level concurrency and retry policy;
- sequence discovery, fingerprinting, and validation profiles;
- poll compact run status and classify workflow failures;
- retain orchestration history;
- trigger focused scans after relevant deployment, DNS, route, firewall, cloud-address, or template changes.

Kestra reports dispatch, timeout, retry-exhaustion, and missing-result failures.
Grafana remains the single owner of vulnerability, exposure, scanner-freshness,
and coverage alerts so findings are not routed twice.

### Workflow stages

Kestra must own a real staged DAG, not a single scheduled `run everything`
command. The scanner executes each bounded stage and returns an immutable
artifact/status reference under the Kestra run ID.

1. **Target snapshot** — compile declared and observed targets with provenance
   and freeze the run's input manifest.
2. **Discovery** — execute approved target-group shards such as home,
   Gigahub, AWS public/private, and GCP public/private while scanner-side
   controls enforce the aggregate and per-host rates.
3. **Merge and diff** — validate required shard coverage, merge listeners, and
   compare them with the previous successful service inventory.
4. **Fingerprint** — probe only new or changed listeners with targeted service
   detection and HTTP/TLS normalization.
5. **Validation and finalize** — branch confirmed protocols into approved
   Nuclei or network-service profiles, then persist the complete run lineage,
   coverage, findings, and terminal status.

If merge and diff finds no new or changed listeners, the workflow skips
fingerprinting and vulnerability validation and finalizes the discovery result.
A remediation or newly approved CVE template may start a focused validation
workflow from an existing immutable service artifact instead of repeating
estate discovery.

Every stage/shard must be idempotent by run ID, stage, and target group. Kestra
retries only the failed stage or shard; a failed GCP validation must not repeat
a successful 116.5-million-probe estate discovery. Kestra records the
dependencies and retry history, while large scanner artifacts remain on the
scanner/ClickHouse path rather than flowing through Kestra storage.

The scanner control interface therefore exposes bounded operations, for example:

```text
aether-scan targets snapshot <run-id> <profile>
aether-scan discover <run-id> <target-group>
aether-scan merge-diff <run-id>
aether-scan fingerprint <run-id> <service-artifact>
aether-scan validate <run-id> <service-artifact> <approved-profile>
aether-scan finalize <run-id>
aether-scan status <run-id> <stage> [target-group]
```

These are typed dispatcher operations, not shell fragments. Naabu, Nmap, httpx,
Nuclei arguments, batching, and ClickHouse writes remain scanner implementation
details. If implementation collapses the workflow into one opaque scanner
command, Kestra adds no meaningful orchestration and the design must use local
systemd timers instead.

### Scanner responsibilities

- validate the requested run ID and profile;
- compile the profile's authoritative targets locally;
- enforce scope, rate, timeout, template, and safety policy;
- acquire the local exclusive lock;
- start a detached systemd execution unit;
- normalize and write results directly to ClickHouse;
- expose only compact status to the orchestrator;
- reject unknown profiles and caller-supplied commands, targets, rates, templates, and output paths.

The accepted execution must not remain attached to the SSH session. A Kestra or
Kubernetes interruption may prevent new dispatches, but it must not kill a scan
already accepted by the guest.

### Dispatch identity and network policy

Use a dedicated `kestra-estate-scanner` SSH identity with:

- a forced command invoking the scanner dispatcher;
- no interactive shell, PTY, sudo, port forwarding, or agent forwarding;
- no administrative or application credentials;
- authorization only for known profile names, valid run IDs, and approved target-group names.

The Kestra namespace already declares allowlisted egress. Add only the verified
Kestra execution path to the scanner's TCP 22 dispatch endpoint; do not grant
Kestra general access to VLAN 2 or the scanned networks. The scanner firewall
must distinguish the dispatch identity/path from operator administration.

Scanner profiles are reviewed declarations such as:

```text
discovery-common
critical-full-tcp
known-hosts-full-tcp
estate-blind-full-tcp
udp-common
nuclei-daily
nuclei-weekly
cloud-public
cloud-private
```

The scanner may use systemd transient or templated units for resource isolation,
status, and cancellation. It must not duplicate Kestra's calendar schedules.
Prometheus/Grafana independently alert when the expected successful-run timestamp
or target coverage becomes stale. Aether owns these platform scanning workflows;
they do not belong to the sibling Inquest incident-lifecycle repository.

### LXC capability gate

Naabu SYN discovery requires raw-socket access. The deployment must prove that an unprivileged LXC can run the required mode with only a narrow capability such as `CAP_NET_RAW`.

Acceptance conditions:

- the container remains unprivileged;
- no host devices or broad host networking are exposed;
- the scanner can emit SYN probes from its dedicated address;
- the scanner cannot reconfigure the host or other guests;
- result accuracy is verified against a controlled target.

If these conditions fail, replace the LXC design with a 2-vCPU, 4-GiB VM on `neo`. Do not weaken the container boundary to preserve the LXC choice.

## Schedule

Kestra is the canonical scheduler for every cadence below. The scanner guest
contains execution units and housekeeping only, not parallel `OnCalendar`
schedules.

| Cadence | Scope | Purpose |
| --- | --- | --- |
| Continuous | Zeek, DNS, DHCP/neighbor, IaC, cloud, and Kubernetes evidence | Discover communicating and declared assets |
| Every 6 hours | Top approximately 1,000 TCP ports across all seven `/24`s | Find new hosts and common services, including ICMP-silent devices |
| After discovery | HTTP/TLS and targeted service fingerprinting on new or changed listeners | Produce canonical service targets |
| Daily | All TCP ports on public cloud, private cloud, public edge, identity, PKI, secrets, control-plane, and other critical assets | Short detection window for high-risk systems |
| Daily and on change | Safe Nuclei against public, critical, new, and changed services | Detect exposure and vulnerability drift |
| Weekly | All TCP ports on declared, active, and last-30-day hosts | Deep estate coverage without scanning empty addresses constantly |
| Weekly | Broader reviewed safe Nuclei profile | Revalidate all confirmed services |
| Monthly | All 65,535 TCP ports across every address in all seven `/24`s | Catch silent undeclared hosts listening only on uncommon ports |
| Monthly | Common and estate-relevant UDP ports on declared/observed hosts | Cover DNS, SNMP, NTP, IPsec, mDNS, SSDP, WireGuard, and similar services |
| Immediate | Relevant deployment, route, firewall, DNS, template, or public-exposure change | Verify the changed surface |

Published baselines are less aggressive: CIS Controls v8 specifies quarterly-or-more-frequent internal vulnerability scans and monthly-or-more-frequent scans of externally exposed assets. This plan uses monthly only for the expensive blind sweep; its practical detection loop is continuous, six-hourly, daily, and weekly.

## Initial rates

Start conservatively and raise rates only from measured evidence:

| Target class | Initial per-host rate |
| --- | ---: |
| Servers and infrastructure | 100 probes/s (raised from 25 after Phase 3 full-TCP calib) |
| Ordinary clients | 10 probes/s |
| IoT and media devices | 5 probes/s |
| Gigahub and ISP-managed equipment | 5 probes/s |

Initial global controls:

- discovery: 1,000 packets/s;
- httpx: 25 requests/s;
- Nuclei: 20 requests/s;
- Nuclei per-host concurrency: 2–4;
- no overlapping runs;
- hard execution deadlines;
- scanner jobs run at low CPU and I/O priority.

Observe VyOS CPU and connection tracking, endpoint errors, Zeek/Suricata processing, ClickHouse ingestion, scanner memory, packet loss, and scan completeness before increasing the global rate toward 2,000–5,000 packets/s.

## Nuclei policy

### Supply chain and reproducibility

- Pin the Nuclei binary/container digest.
- Pin the `nuclei-templates` release or commit and verify its checksum/signature.
- Record scanner and template revisions on every run.
- Review template upgrades through the normal code-review path.
- Never run an unreviewed template update immediately before a scheduled scan.

### Profiles

Retain informational, low, medium, high, and critical results. Severity controls routing, not collection.

Exclude by default:

- DoS;
- fuzzing;
- brute force and credential stuffing;
- intrusive or mutating templates;
- arbitrary code templates;
- unsigned local/community templates;
- templates that create, upload, delete, or modify target data.

Headless/browser and authenticated templates require separate reviewed profiles. Authenticated scanning must use dedicated read-only test identities and explicit endpoint boundaries; it is deferred from the initial rollout.

## Host posture without Fleet

Fleet is being retired and is not a dependency of this design.

Use Wazuh agents over the private WireGuard fabric for cross-estate host posture where supported:

- package and vulnerability inventory;
- security configuration assessment;
- file-integrity monitoring;
- users, authentication, processes, and services;
- relevant host logs.

The existing Wazuh manager listens on the IDS stack, but a reusable Wazuh agent deployment role is not currently declared. P1 monitoring hardening owns that role and must audit/enroll every Fleet-covered host before Fleet removal; this scanner plan consumes the resulting posture data rather than sequencing agent deployment after retirement. Enroll AWS/GCP agents over `10.1.0.10` and `10.2.0.10`, not public interfaces.

If `vm_monitoring_agent` remains for OTEL host metrics and journals during Fleet removal, its osquery enrollment must be removed or disabled. OTEL remains the metrics/log transport; it does not replace Wazuh host-security coverage.

Do not assume Amazon Inspector covers Lightsail. Use Wazuh, Amazon Linux package advisory state, Ansible-managed patching, and network scanning. Use GCP OS Config as an additional provider-native source for the Debian uptime monitor.

## Data model

Use ClickHouse for normalized history and Loki for execution logs.

### Scan runs

Record:

- run ID and profile;
- vantage point;
- scanner and template revisions;
- start, finish, and status;
- target and probe counts;
- error, timeout, and dropped-target counts.

### Assets

Record:

- stable asset identity;
- IPv4/IPv6 and DNS names;
- cloud, Kubernetes, Tailscale, or MAC identity when available;
- declared versus discovered state;
- provenance and owning source file;
- first seen and last seen;
- observed vantage points.

### Services

Record:

- asset, transport, and port;
- detected protocol/product evidence;
- canonical HTTP URL and TLS identity;
- declared versus unexpected state;
- first seen, last seen, and resolved time;
- scan evidence and confidence.

### Findings

Record:

- stable finding key;
- target, template ID, matcher, and severity;
- evidence without unnecessary secrets;
- first seen, last seen, current/resolved state;
- scanner and template versions;
- exposure, owner, suppression, and review status.

## Telemetry handling

A live query on 2026-07-12 found approximately 1.47 million `zeek.conn` rows in the preceding 24 hours and 10.1 million rows in the retained 14-day window. A 116.5-million-flow blind sweep could therefore exceed eleven times the then-current retained row count if every probe became a connection record.

The scanner's dedicated source identity enables narrow handling:

- scanner results are the authoritative record for expected closed/time-out probes;
- repetitive unsuccessful authorized scan flows are aggregated by run/network/state instead of stored one-for-one in general connection tables;
- successful handshakes, application exchanges, unexpected responses, unauthorized destinations, and off-schedule scanner traffic remain visible;
- Suricata flow and scan-alert handling receives the same treatment so noise is not merely shifted from Zeek;
- no blanket scanner-IP exclusion is allowed.

Alert if the scanner identity emits traffic outside its approved schedule, scope, or profile.

## Alerts

Start with a small, high-signal set:

1. New undeclared asset.
2. New externally reachable listener.
3. New unexpected management service.
4. New critical Nuclei finding on a public or critical target.
5. New high Nuclei finding.
6. Declared critical endpoint disappeared.
7. Listener, product, TLS identity, or exposure changed.
8. Scanner run stale, failed, incomplete, or sharply reduced in coverage.
9. Scanner traffic outside the approved schedule or destination scope.

Informational and low findings enrich inventory. Medium findings appear in dashboards/digests. High findings create a review item. Public critical findings page after the initial baseline and tuning period.

## Rollout

### Phase 0 — preflight

- Recheck `neo` CPU, memory, storage, and network headroom.
- Allocate the scanner address through authoritative inventory.
- Verify VyOS routes and intended firewall reachability from VLAN 2 to every approved network and cloud site identity.
- Confirm the scanner source will be visible on the mirrored path.
- Define ClickHouse schemas, retention, and Grafana datasource access before generating high-volume traffic.
- Define scan-aware Zeek and Suricata handling without blanket exclusions.

#### Phase 0 progress (2026-07-12)

- **neo headroom (live):** ~123 GiB total RAM, ~48 GiB available (~60.9% used; 7d avg ~58.4%, max ~61.6%). Guests: `talos-neo`, `nix-builder`. Root ~78 GiB free. 4 GiB scanner fits.
- **Allocated identity:** `estate_scanner` in `config/vm.yml` — VMID `1036`, IP `10.0.2.13`, VLAN 2, node `neo` (do not reuse `10.0.2.7`).
- **ClickHouse:** `estate_scan` schema in `ansible/playbooks/monitoring_stack/clickhouse/11-estate-scan-schema.sql`; apply with `task configure:estate-scan-schema`. Grafana `grafana_readonly` SELECT includes `estate_scan`.
- **IDS design:** no blanket scanner-IP exclusion; expected failed probes → `estate_scan.probe_aggregates`; meaningful responses stay in Zeek/Suricata. Pointer in `nix/hosts/oracle/ids-stack/zeek.nix`. VyOS mirrors `eth1` → same-L2 VLAN 2 probes may not appear on the mirror.
- **Not done in Phase 0:** live guest provision, CAP_NET_RAW proof, Kestra DAG, production scans.

### Phase 1 — scanner guest

- Declare the guest and address in `config/vm.yml` (and provision via Ansible NixOS LXC on `neo`, not OpenTofu VM, unless the CAP_NET_RAW gate forces a VM fallback).
- Configure the OS, administrative access, time synchronization, DNS, firewall, and telemetry through the established guest-management path.
- Install pinned Naabu, Nmap, httpx, Nuclei, and template revisions.
- Add the forced-command dispatcher and hardened, non-overlapping, Kestra-dispatched systemd execution units.
- Prove the unprivileged raw-socket capability gate or switch the design to a VM.
- Add the narrow Kestra egress allowlist and scanner-side dispatch firewall rule after verifying the actual source path.
- Declare the Aether-owned staged Kestra DAG, approved profiles, schedules, conditional branches, shard-level retries, and change triggers.

#### Phase 1 progress (2026-07-13)

- Live unprivileged NixOS LXC `1036` / `10.0.2.13` on neo; CAP_NET_RAW proven.
- Babashka `aether-scan.bb`: targets → discover (profile-driven ports/rates) →
  merge-diff → fingerprint → validate → finalize; ClickHouse writers live.
- Kestra SSH identity + VyOS rule 26 + `aether.estate/estate-scan-home` E2E SUCCESS.
- Profile modes: `discovery-common` (top-100), `critical-full-tcp` / `known-hosts-full-tcp`
  (all TCP @ 100pps), IoT/Gigahub group caps at 5pps; `cidr-infra` expands `10.0.2.0/24`.
- Production calendar schedules still deferred to Phase 4 (Kestra remains schedule authority).

### Phase 2 — inventory and storage

- Generate targets from authoritative declarations and observed evidence.
- Implement normalized scan-run, asset, service, and finding writes.
- Preserve provenance and vantage point.
- Add Grafana coverage, inventory-diff, and finding panels.
- Add stale/failed scanner alerts before enabling broad scans.

#### Phase 2 progress (2026-07-13)

- Declared targets + CIDR provenance writes to `estate_scan.{scan_runs,assets,services}`.
- Grafana dashboard `uid: estate-scan` provisioned (coverage stats, recent runs, inventory, findings).
- Alerts `estate-scan-run-stale` (>12h without success) and `estate-scan-run-failed` (any failure in 6h).
- **Automated hostname inventory (2026-07-13):** baked from tofu
  `synthetic_probe_targets` (`*.shdr.ch` only) into
  `/etc/estate-scanner/inventory-declared.json` via
  `task estate-scanner:inventory-declared` + `configure:estate-scanner`.
  Guest stage `inventory-sync` merges CT (`crt.sh` `%shdr.ch`) with retries +
  last-known-good; CT-only names are **report-only** (CH + Grafana), never
  Nuclei. Validate merges declared hostname HTTPS URLs with IP fingerprint
  URLs in **one** Nuclei pass. Findings join `dns:<fqdn>` assets.
  Verified live: 95 scannable / 46 CT-only; `grafana.home.shdr.ch` in
  `inventory-https.txt`; CT-only excluded from that list; CH
  `estate_scan.inventory_names` + `dns:` assets populated.
  Schema: `estate_scan.inventory_names` + `inventory_observations`.
- `seven30.xyz` / non-`shdr.ch` synthetic probes stay on blackbox, not estate Nuclei.
- Observed/passive (Zeek) inventory union and cloud target resolution remain later work.
- Phase 4 calendars still blocked on findings review + SSH host-key pin in Kestra
  (`config/ssh/estate-scanner.known_hosts`; plugin lacks `knownHosts` today).

### Phase 3 — calibration

- Scan controlled test targets.
- Scan one server-class host across all TCP ports.
- Scan representative IoT and Gigahub devices at the lowest rate.
- Run one `/24` common-port sweep.
- Verify accuracy, duration, endpoint behavior, VyOS state, IDS processing, and ClickHouse growth.
- Tune rates and timeouts from evidence.

#### Phase 3 progress (2026-07-13)

| Run | Scope | Result | Duration |
| --- | --- | --- | ---: |
| controlled | undeclared `nc` on `10.0.2.3:41777` | naabu connect found listener | ~2s |
| `b0d28eab-…` | IoT (`10.0.3.9`) top-100 @ 5pps | 2 listeners / 1 host | 32s |
| `19f5756e-…` | Gigahub (incl. `192.168.2.1`) top-100 @ 5pps | 14 listeners / 5 hosts | 164s |
| `6801183e-…` | `10.0.2.0/24` top-100 @ 100pps | 33 listeners / 254 addrs | 623s |
| `d3a43b83-…` | monitoring-stack full TCP @ 100pps | 17 listeners | 660s |

- **Rate tune:** full-TCP at 25pps/timeout=5 stalled on filtered ports; raised
  `critical-full-tcp` to 100pps/timeout=2/concurrency=25. IoT/Gigahub stay capped at 5pps.
- **IDS:** Suricata recorded scanner-sourced noise during sweeps (expected); no
  blanket exclusion. Naabu output streams to artifact files (not memory) for full-port runs.
- **Not done in Phase 3:** production schedules, notification routing, cloud calib.
- **Nuclei calib gap:** validate was declared wired, but the only successful L7
  run after the fix scanned **2 URLs** (`10.0.2.2:80`, `10.0.2.3:3000`) with
  curated medium+ templates → 0 findings. Full HTTP inventory (~22 URLs in the
  last fingerprint) has not been Nuclei-validated.

### Phase 3.5 — finish a real working L7 system (before Phase 4)

Phase 4 is calendars. This section is unfinished Phase 1–3 acceptance work.

#### Gaps to close (order matters — Codex second opinion 2026-07-13)

1. **ClickHouse bookkeeping** — done: `finalize!` reads profile from
   `targets.json`; `reap-stale` / `abandon` close orphans; validate writes
   `validate-evidence.json` with URL/findings/duration; string Nuclei ports no
   longer crash `write-findings!` (`ingest-validate` recovers crashed writers).
2. **Full Nuclei baseline** — done: run `4017b09c-74d1-4019-8f5b-d90178e6c5aa`
   scanned 23 URLs (~72m), `nuclei-daily`, CH `succeeded`, probe_count=23.
3. **Known-positive fixture** — done: `estate-nuclei-fixture-http` on
   `127.0.0.1:18080` + template `aether-estate-scan-fixture` → 1 medium finding
   in CH for that run.
4. **Kestra flow IaC** — done: `tofu/home/kestra-flows/` (S3 key
   `kestra-flows.tfstate`); `task tofu:kestra-flows:apply`.
5. **Baseline vs incremental L7** — done: `merge-diff` writes
   `services-all.jsonl` + `services-changed.jsonl`; flow input `l7_scope`
   (`full` default / `changed`); validate timeout 90m; Kestra poll max PT100M.
6. **Meaningful Grafana findings** — done: dashboard `estate-scan` shows 23 open
   findings; orphan `running`/`accepted` older than 6h = 0 after reap.

#### Acceptance for “real working system”

- [x] Full-fingerprint `nuclei-daily` completes with stage + CH `succeeded` and
  correct profile label (`nuclei-daily`).
- [x] Findings rows appear (23 open; fixture + estate medium/critical hits).
- [x] No orphan `running`/`accepted` scan_runs older than 6h without a live lock.
- [x] Kestra can dispatch validate→finalize; flow is in IaC.
- [ ] Only then enable Phase 4 schedules (still blocked on human review of open findings).

### Phase 4 — progressive coverage

- Enable six-hour common-port discovery.
- Enable daily critical/cloud full-port and Nuclei scans.
- Enable weekly known-host full-port and broader safe Nuclei scans.
- After at least one stable week, run the first monthly blind seven-network sweep.
- Baseline findings before enabling high/critical notification routing.

### Phase 5 — posture correlation

- Consume the Wazuh coverage delivered as the P1 prerequisite to Fleet retirement.
- Confirm AWS and GCP posture evidence arrives over WireGuard and from GCP OS Config.
- Correlate network services and findings with Wazuh and provider-native evidence.
- Do not restore an osquery/Fleet dependency or make Fleet retirement wait on scanner rollout.

## Verification

The rollout is complete only when all of the following are demonstrated:

- an undeclared controlled test listener is discovered and classified;
- an ICMP-silent test host is found through TCP discovery;
- a declared service disappearing produces the expected state transition;
- public and private AWS/GCP observations remain distinct;
- the GCP public target follows an address change without manual editing;
- a safe known Nuclei fixture produces a normalized finding and resolves cleanly;
- scanner failure and stale coverage alerts fire in a controlled test;
- Kestra can dispatch every approved profile but cannot execute an arbitrary command or override scanner policy;
- an accepted scan finishes and records its result after the dispatch SSH session is interrupted;
- duplicate local calendar schedules do not exist on the scanner;
- Kestra workflow failures and Grafana finding/coverage alerts remain distinct;
- a no-change discovery run skips fingerprinting and vulnerability validation;
- a failed target-group shard retries without repeating successful discovery shards;
- a failed downstream validation retries without repeating estate discovery;
- every final result links to its immutable target snapshot, stage artifacts, retries, and scanner/template revisions;
- no Kestra workflow delegates the complete pipeline to one opaque scanner command;
- Zeek and Suricata retain meaningful responses without ingesting every expected failed probe;
- VyOS has no material packet loss, latency, CPU, or connection-tracking regression;
- IDS collection remains healthy during the largest enabled scan;
- ClickHouse retention and query performance remain within their declared limits;
- off-schedule scanner traffic remains detectable;
- no production target is mutated by the approved Nuclei profile.

## Future Oracle work

A future, separately approved hardware/topology change may:

- increase Oracle from 16 GiB to 32 GiB when pricing is reasonable;
- soak-test the memory upgrade and confirm swap pressure falls;
- add a control-plane-only Talos VM while preserving physical etcd fault-domain diversity;
- reserve adequate memory for Proxmox, VyOS, gateway, identity, PKI, secrets, and IDS workloads.

That future work does not move the scanner back to Oracle and is not a prerequisite for this plan.

## Authoritative implementation paths

- VM/LXC facts and placement: `config/vm.yml` (`estate_scanner`: `10.0.2.13`, VMID `1036`, node `neo`)
- Guest provisioning: `ansible/playbooks/estate_scanner/` (NixOS unprivileged LXC; VM fallback only if CAP_NET_RAW gate fails)
- Guest NixOS config: `nix/hosts/neo/estate-scanner/`
- VyOS VLANs, routes, and firewall: `ansible/playbooks/home_router/`
- IDS stack: `tofu/home/ids_stack.tf`, `nix/hosts/oracle/ids-stack/`
- AWS compute and exposure: `tofu/aws/public-gateway.tf`
- AWS site configuration: `ansible/playbooks/public_gateway_stack/`
- GCP compute: `tofu/google/uptime-monitor.tf`
- GCP site configuration: `ansible/playbooks/uptime_monitor_stack/`
- Kubernetes application exposure: `tofu/home/kubernetes/`
- ClickHouse and Grafana: `ansible/playbooks/monitoring_stack/` (`clickhouse/11-estate-scan-schema.sql`)
- Kestra platform and namespace contract: `tofu/home/kubernetes/kestra.tf`, `tofu/home/kubernetes/namespace_contracts.tf`
- Scanner workflow declarations: `tofu/home/kestra-flows/` (`task tofu:kestra-flows:apply`); flow source `kestra/flows/estate-scan-home.yaml`. Not sibling Inquest flow IaC.
- Existing historical network-security proposal: `docs/exploration/network-security.md`
