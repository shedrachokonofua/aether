# NixOS Exploration

Exploration of NixOS for foundational VMs — declarative, reproducible, and atomically rollbackable infrastructure.

## Goal

Replace Fedora + Ansible with NixOS for VMs that:

1. **Stay outside K8s** — foundational services K8s depends on
2. **Need reliability** — identity, secrets, observability, networking
3. **Benefit from atomic rollbacks** — bad config? instant recovery

## What Changes

| VM               | Current          | Becomes   | Why NixOS                                    |
| ---------------- | ---------------- | --------- | -------------------------------------------- |
| Gateway Stack    | Fedora + Ansible | NixOS     | Ingress for everything, needs reliability    |
| Monitoring Stack | Fedora + Ansible | NixOS     | Must survive K8s failures                    |
| Dev Workstation  | Fedora + Ansible | NixOS     | Reproducible dev environment                 |
| Media Stack      | Fedora + Ansible | NixOS     | Complex stack, rollback valuable             |
| IoT Stack        | Fedora + Ansible | NixOS     | USB passthrough works, declarative HA config |
| Cockpit          | Fedora + Ansible | NixOS     | Minimal change, good starter                 |
| Keycloak         | LXC              | NixOS LXC | Critical identity provider                   |
| step-ca          | LXC              | NixOS LXC | Critical PKI root                            |
| OpenBao          | LXC              | NixOS LXC | Critical secrets management                  |
| AdGuard          | LXC              | NixOS LXC | DNS for everything                           |

## What Stays As-Is

| VM/Host         | OS            | Why Not NixOS                     |
| --------------- | ------------- | --------------------------------- |
| Router          | VyOS          | Purpose-built network OS          |
| Gaming Server   | Bazzite       | Purpose-built immutable gaming OS |
| GPU Workstation | Fedora        | NVIDIA drivers, complex GPU stack |
| K8s Nodes       | Talos         | Purpose-built for Kubernetes      |
| Proxmox Hosts   | Debian        | Too risky, minimal benefit        |
| Smith LXCs      | Alpine/Debian | Storage infrastructure, stable    |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NIXOS FOUNDATIONAL LAYER                             │
│                                                                              │
│   Oracle:                      Niobe:                    Trinity:            │
│   ├── gateway.nix              ├── monitoring.nix        ├── dev.nix        │
│   │   ├── Caddy                │   ├── Prometheus        │   └── Coder      │
│   │   ├── Tailscale            │   ├── Grafana           │                   │
│   │   ├── HAProxy              │   ├── Loki              ├── media.nix      │
│   │   └── WireProxy            │   ├── Tempo             │   ├── Jellyfin   │
│   │                            │   └── OTEL              │   ├── qBit+VPN   │
│   ├── keycloak.nix             │                         │   └── Calibre    │
│   │   └── Keycloak             ├── iot.nix               │                   │
│   │                            │   ├── Home Assistant    │                   │
│   ├── step-ca.nix              │   ├── Z-Wave            │                   │
│   │   └── step-ca              │   └── Thread            │                   │
│   │                            │                         │                   │
│   ├── openbao.nix              └── cockpit.nix           │                   │
│   │   └── OpenBao                  └── Cockpit           │                   │
│   │                                                      │                   │
│   └── adguard.nix                                        │                   │
│       └── AdGuard Home                                   │                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                    trusts (OIDC, certs, secrets)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    KUBERNETES + OTHER WORKLOADS                              │
│   Talos K8s, VyOS, GPU Workstation, Gaming Server                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Key Unlocks

### Declarative Everything

| What              | How                                                                                |
| ----------------- | ---------------------------------------------------------------------------------- |
| Native services   | `services.prometheus.enable = true`                                                |
| Podman containers | [quadlet-nix](https://github.com/SEIAROTg/quadlet-nix) — declarative Quadlet units |
| Secrets           | sops-nix (age-encrypted in repo)                                                   |
| Disk partitioning | disko (declarative partitions)                                                     |

### Podman via quadlet-nix

Containers managed as systemd units through [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html):

- Containers, pods, networks, volumes — all in Nix
- Automatic dependency ordering
- Systemd integration (logs, restart policies, health checks)
- No Docker daemon, no Ansible docker_container module
- Works with `pkgs.dockerTools.buildImage` for Nix-built images

### Atomic Rollbacks

| Scenario            | Recovery                             |
| ------------------- | ------------------------------------ |
| Bad config deployed | `nixos-rebuild --rollback` (instant) |
| Service won't start | Boot previous generation from GRUB   |
| Need to test change | `nixos-rebuild build-vm` (local VM)  |

### Zero Drift

- Config IS the system state — not a description of desired changes
- Re-running `nixos-rebuild switch` is idempotent
- `flake.lock` pins exact versions of everything

### Dev Shell

`nix develop` in aether repo gives reproducible CLI environment:

- opentofu, ansible, kubectl, talosctl, sops, age
- All pinned versions via `flake.lock`
- Works on any machine with Nix installed

## Repository Structure

```
aether/
├── nix/
│   ├── flake.nix                 # Flake root
│   ├── flake.lock                # Pinned dependencies
│   ├── hosts/                    # Per-VM configurations
│   │   ├── oracle/
│   │   ├── niobe/
│   │   └── trinity/
│   ├── modules/                  # Reusable modules
│   │   ├── base.nix              # Common config (users, SSH, OTEL)
│   │   └── podman.nix            # quadlet-nix defaults
│   └── shells/
│       └── default.nix           # aether dev environment
│
├── ansible/                      # Remaining (GPU Workstation, Smith LXCs, etc.)
├── tofu/                         # VM provisioning (unchanged)
└── ...
```

## Secrets Management

| Tool     | Scope                                    |
| -------- | ---------------------------------------- |
| sops-nix | NixOS VM secrets (age-encrypted in repo) |
| OpenBao  | K8s secrets, dynamic credentials         |

sops-nix decrypts at activation time → secrets never in Nix store.

## Deployment

```bash
# From workstation
nixos-rebuild switch --flake .#gateway --target-host root@gateway

# Or via GitLab CI on nix/** changes
```

## Benefits vs Ansible

| Aspect               | Ansible + Fedora                 | NixOS                             |
| -------------------- | -------------------------------- | --------------------------------- |
| Drift                | Can drift between runs           | Impossible — config IS state      |
| Rollback             | Snapshot or manual               | `nixos-rebuild --rollback`        |
| Reproducibility      | Best effort                      | Guaranteed (flake.lock)           |
| Partial failures     | Service might be half-configured | Atomic — all or nothing           |
| Container management | Ansible docker_container         | quadlet-nix (declarative systemd) |

## What Ansible Remains For

| Target          | Why                             |
| --------------- | ------------------------------- |
| GPU Workstation | NVIDIA complexity, stays Fedora |
| Smith LXCs      | Storage infra, minimal change   |
| Proxmox hosts   | host_monitoring_agent role      |
| VyOS            | vyos_config module              |
| Public Gateway  | AWS, stays Amazon Linux         |

## Migration Strategy

| Phase | Target                    | Risk                                     |
| ----- | ------------------------- | ---------------------------------------- |
| 1     | Dev shell (`nix develop`) | None                                     |
| 2     | Cockpit                   | Lowest — minimal services                |
| 3     | Gateway Stack             | Medium — high value                      |
| 4     | Identity Stack (Oracle)   | Medium — rebuild LXCs via nix-generators |
| 5     | Monitoring Stack          | Medium — declarative alerting            |
| 6     | Media + IoT               | Lower priority                           |

### NixOS in LXC

NixOS runs fine in Proxmox LXC ([reference](https://taoofmac.com/space/blog/2024/08/17/1530)). Use [nixos-generators](https://github.com/nix-community/nixos-generators) to build container images directly from your flake:

```bash
nix run github:nix-community/nixos-generators -- -f proxmox-lxc -c hosts/oracle/keycloak.nix
```

Lower overhead than VMs, same declarative benefits.

## Tool Responsibilities

| Concern           | Tool                     |
| ----------------- | ------------------------ |
| Create VM         | Tofu (Proxmox provider)  |
| Configure VM      | NixOS                    |
| Container runtime | Podman (via quadlet-nix) |
| Package versions  | NixOS (flake.lock)       |
| Secrets (K8s)     | OpenBao                  |
| Secrets (NixOS)   | sops-nix                 |

**Tofu provisions, Nix configures, Podman runs containers.**

## Status

**Exploration complete.** Ready to implement starting with dev shell + Cockpit VM.

## Related Documents

- `kubernetes.md` — K8s workloads (complementary)
- `../trust-model.md` — Identity architecture
- `../paas.md` — Dokku/Dokploy being replaced by Kubero
