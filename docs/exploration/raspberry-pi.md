# Raspberry Pi Exploration

Exploration of using spare Raspberry Pis for lifeboat access and Kubernetes ARM workers.

## Goal

Put 3 spare Raspberry Pis to use:

1. **Lifeboat** — Break-glass access when the Proxmox cluster is down
2. **ARM k8s workers** — Extend the Kubernetes cluster with ARM nodes
3. **wasmCloud edge** — Portable Wasm workloads across architectures

## Current State

| Pi    | RAM | Status          |
| ----- | --- | --------------- |
| Pi #1 | 4GB | Sitting on desk |
| Pi #2 | 4GB | Sitting on desk |
| Pi #3 | 4GB | Sitting on desk |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster (Talos)                  │
│                                                                 │
│   [talos-1]  [talos-2]  [talos-3]     (x86 VMs, control+worker) │
│   [pi-2]     [pi-3]                   (ARM, worker-only)        │
│                                                                 │
│   wasmCloud on all nodes → Wasm components are arch-agnostic    │
│   Ceph storage available → Pi workers use Ceph RBD, not SD card │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│   [Pi #1] ← Standalone lifeboat (VLAN 1, Tailscale)             │
│   NOT in cluster. Break-glass access when cluster is down.      │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│   [Lightsail] ← External monitoring (blackbox checks)           │
│   Already exists. Pings critical services, alerts via ntfy.     │
└─────────────────────────────────────────────────────────────────┘
```

## Pi Roles

### Pi #1: Lifeboat (Standalone)

Tailscale subnet router on VLAN 1 (Gigahub LAN). Provides break-glass access when VyOS/Proxmox is down.

| Feature        | Value                                              |
| -------------- | -------------------------------------------------- |
| VLAN           | 1 (Gigahub, 192.168.2.0/24)                        |
| Tailscale      | Subnet router for 192.168.2.0/24                   |
| In k8s cluster | ❌ No                                              |
| Purpose        | SSH via Tailscale → reach PiKVM/IPMI → fix cluster |

**Why standalone:** If it's in the k8s cluster and the cluster dies, you can't reach it. The whole point is independence.

**Firewall:**

```bash
# Allow Tailscale
iptables -A INPUT -i tailscale0 -j ACCEPT

# Allow SSH from VLAN 1 (local emergency access)
iptables -A INPUT -i eth0 -p tcp --dport 22 -s 192.168.2.0/24 -j ACCEPT

# Block everything else on physical interface
iptables -A INPUT -i eth0 -j DROP
```

### Pi #2 & #3: Kubernetes ARM Workers

Talos Linux, worker-only nodes joining the main cluster.

| Feature | Value                          |
| ------- | ------------------------------ |
| OS      | Talos Linux (ARM64)            |
| VLAN    | 2 (Infrastructure)             |
| Role    | Worker-only (no control plane) |
| Storage | Ceph RBD via CSI (not SD card) |
| Labels  | `kubernetes.io/arch=arm64`     |

**Capacity:**

| Pi        | RAM | Usable (after Talos overhead) |
| --------- | --- | ----------------------------- |
| Pi #2     | 4GB | ~3.4GB                        |
| Pi #3     | 4GB | ~3.4GB                        |
| **Total** | 8GB | **~7GB ARM capacity**         |

**Why Talos:** Same OS as x86 nodes. Same tooling (`talosctl`), same configs. Consistency.

**Why Ceph:** SD cards are slow and wear out. Ceph RBD over network is faster for random I/O and data is replicated.

### wasmCloud

wasmCloud runs on Kubernetes (via operator) across all nodes. Wasm components are architecture-agnostic — same `.wasm` file runs on ARM or x86.

| Benefit              | Value                            |
| -------------------- | -------------------------------- |
| No multi-arch images | Wasm is portable                 |
| Lightweight          | wasmCloud host is ~50MB          |
| Edge-native          | Designed for distributed compute |

**Use case:** Lightweight functions, edge processing, IoT coordination.

## Network Configuration

### VLAN Assignments

| Pi    | Role       | VLAN               | Subnet         |
| ----- | ---------- | ------------------ | -------------- |
| Pi #1 | Lifeboat   | 1 (Gigahub)        | 192.168.2.0/24 |
| Pi #2 | k8s worker | 2 (Infrastructure) | 10.0.2.0/24    |
| Pi #3 | k8s worker | 2 (Infrastructure) | 10.0.2.0/24    |

### PoE Switch Setup

**Switch:** Netgear GS305EP (5-port, PoE+, managed)

```
┌──────────────────────────────────────────────────────────────────────┐
│  [Pi1][Pi2][Pi3][—] ══════ [GS305EP]                                 │
│  VLAN1 VLAN2 VLAN2         (managed PoE+)                            │
│                                 │                                    │
│                                 └── uplink loops to back ─────────┐  │
└───────────────────────────────────────────────────────────────────│──┘
                                                                    │
                                                                    ▼
                                                             Patch panel
                                                                    │
                                                                    ▼
                                                     SFP transceiver → QNAP
```

**Why GS305EP:**

- 802.3af/at PoE+ (not passive)
- Managed (VLANs per port)
- 5 ports (3 Pis + uplink + spare)
- 62W budget (plenty for 3 Pis at ~7W each)

**Cable management:**

- Pis and switch on same rack shelf
- Short 6" flat patch cables (Pi → switch)
- Uplink loops to back/side, into patch panel
- Patch panel → SFP-to-RJ45 transceiver in QNAP

## External Monitoring (Lightsail)

Lightsail already exists for public gateway. Add blackbox checks:

```yaml
targets:
  - name: vyos
    url: https://10.0.2.1
    type: tcp
  - name: gateway
    url: https://home.shdr.ch
    type: https
  - name: keycloak
    url: https://auth.shdr.ch/realms/aether/.well-known/openid-configuration
    type: https
  - name: step-ca
    url: https://ca.shdr.ch/health
    type: https
  - name: openbao
    url: https://bao.home.shdr.ch/v1/sys/health
    type: https
```

Alert via ntfy if critical services are down. Works even when home monitoring stack is down.

## What We Decided NOT to Do

### ❌ All 3 Pis as k8s workers

**Why not:** Lose the lifeboat. If cluster dies, no break-glass access.

### ❌ Buy a new 8GB/16GB Pi

**Why not:** Not justified. 3x 4GB Pis provide ~7GB ARM capacity. See if limits are hit first.

### ❌ Pis as standalone wasmCloud hosts (not in k8s)

**Why not:** Added complexity. wasmCloud on k8s + Pis as k8s workers = same lattice, simpler management.

### ❌ Unicorn switch (front ports + rear uplink)

**Why not:** Doesn't exist in small PoE+ managed form factor. Worked around with same-shelf layout + patch panel.

### ❌ MikroTik CSS106/RB260GSP

**Why not:** Passive PoE only. Would fry standard Pi PoE+ HATs.

### ❌ Efficiency/cost savings play

**Why not:** Proxmox nodes already running 24/7. Adding Pis adds power draw (~15W). VMs are "free" on existing hardware.

## Cost

| Item                         | Qty | ~Price CAD |
| ---------------------------- | --- | ---------- |
| Netgear GS305EP              | 1   | $80        |
| SFP-to-RJ45 transceiver      | 1   | $20        |
| Pi PoE+ HATs                 | 3   | $60        |
| Short flat patch cables      | 3   | $15        |
| Patch cable (switch → panel) | 1   | $5         |
| **Total**                    |     | **~$180**  |

Pis already owned. No new Pi purchase needed.

## Implementation Phases

### Phase 1: Hardware Setup

- [ ] Purchase GS305EP, transceiver, PoE HATs, cables
- [ ] Install PoE HATs on Pis
- [ ] Mount Pis on rack shelf
- [ ] Cable: Pis → GS305EP → patch panel → QNAP
- [ ] Configure GS305EP VLANs (port 1 = VLAN 1, ports 2-3 = VLAN 2)

### Phase 2: Lifeboat Pi

- [ ] Install Raspberry Pi OS Lite on Pi #1
- [ ] Configure static IP on VLAN 1 (192.168.2.x)
- [ ] Install and configure Tailscale as subnet router
- [ ] Configure iptables (Tailscale + local SSH only)
- [ ] Test: Tailscale → Pi → SSH to PiKVM

### Phase 3: Kubernetes Workers (After k8s cluster exists)

- [ ] Flash Talos ARM64 image to Pi #2 and Pi #3
- [ ] Generate Talos worker configs
- [ ] Apply configs: `talosctl apply-config`
- [ ] Verify nodes join cluster: `kubectl get nodes`
- [ ] Add node labels/taints for ARM workloads

### Phase 4: wasmCloud (Optional)

- [ ] Deploy wasmCloud operator to k8s
- [ ] Configure NATS for lattice communication
- [ ] Deploy test Wasm component
- [ ] Verify component runs on ARM and x86 nodes

### Phase 5: External Monitoring

- [ ] Add blackbox checks to Lightsail
- [ ] Configure ntfy alerts for critical service failures
- [ ] Test: stop a service, verify alert fires

## Failure Modes

| Scenario                 | Lifeboat helps?     | What to do                         |
| ------------------------ | ------------------- | ---------------------------------- |
| Single Proxmox node dies | ❌ (HA handles it)  | Nothing, VMs failover              |
| VyOS dies                | ✅ Yes              | Tailscale → Pi → PiKVM → fix VyOS  |
| All Proxmox nodes die    | ✅ Yes              | Tailscale → Pi → IPMI → boot nodes |
| Ceph loses quorum        | ❌ (bigger problem) | Manual recovery                    |
| Internet dies            | ❌                  | Can't reach Tailscale anyway       |
| Pi dies                  | ❌                  | Keep a spare                       |

## Value Assessment

| Aspect          | Rating   | Notes                                   |
| --------------- | -------- | --------------------------------------- |
| Lifeboat value  | ⭐⭐⭐   | Real, ~1x/year you'll be glad it exists |
| ARM k8s workers | ⭐       | ~7GB capacity, fun but not needed       |
| wasmCloud       | ⭐       | Cool tech, no current Wasm workloads    |
| Learning        | ⭐⭐⭐⭐ | Talos on ARM, multi-arch k8s, wasmCloud |
| Aesthetic       | ⭐⭐⭐⭐ | Visible Pis in rack, blinky lights      |

**Honest take:** The lifeboat is genuinely useful. Everything else is "because I can" — and that's fine for a homelab.

## Related Documents

- `kubernetes.md` — Kubernetes cluster architecture (Pis join this)
- `../networking.md` — VLAN configuration
- `../tailscale.md` — Tailscale mesh
- `../monitoring.md` — Observability (external monitoring complements this)

## Status

**Planning complete.** Ready to purchase hardware and implement.
