# NixOS

Declarative, reproducible infrastructure. Terraform for the OS.

## Vision

Replace imperative configuration (Ansible playbooks, Docker toolbox) with purely declarative Nix. The entire system—from CLI tools to VM configurations—becomes version-controlled, reproducible, and atomically rollbackable.

```
Before: Ansible describes how to reach state → drift possible → rollback = snapshot
After:  NixOS declares what state IS       → no drift      → rollback = built-in
```

## Guiding Principles

| Principle          | Meaning                                                                            |
| ------------------ | ---------------------------------------------------------------------------------- |
| **Config = State** | The Nix configuration IS the system, not a description of steps to reach it        |
| **Reproducible**   | `flake.lock` pins exact versions; rebuild anywhere, get identical results          |
| **Atomic**         | Changes apply all-or-nothing; partial failures impossible                          |
| **Rollback-first** | Every change creates a generation; instant recovery via `nixos-rebuild --rollback` |
| **One Dependency** | Host needs only Nix installed; everything else comes from the flake                |

## End State

### Tool Responsibilities

| Concern               | Tool                        |
| --------------------- | --------------------------- |
| Provision VM/LXC      | OpenTofu (Proxmox provider) |
| Configure OS          | NixOS                       |
| Container runtime     | Podman (via quadlet-nix)    |
| Package versions      | Nix (flake.lock)            |
| Secrets (NixOS)       | sops-nix                    |
| Secrets (K8s)         | OpenBao                     |
| Deploy multiple hosts | colmena (when at scale)     |

### What Becomes NixOS

| Target           | Current               | Becomes       | Status      |
| ---------------- | --------------------- | ------------- | ----------- |
| CLI Toolbox      | Docker container      | `nix develop` | ✅ Complete |
| AdGuard          | Part of Gateway Stack | NixOS LXC     | ✅ Complete |
| IDS Stack        | —                     | NixOS VM      | ✅ Complete |
| Gateway Stack    | Fedora + Ansible      | NixOS VM      | Planned     |
| Monitoring Stack | Fedora + Ansible      | NixOS VM      | Planned     |
| Identity Stack   | LXCs (Fedora)         | NixOS LXCs    | Planned     |
| Dev Workstation  | Fedora + Ansible      | NixOS VM      | Backlog     |

### What Stays As-Is

| Target          | OS            | Why Not NixOS                     |
| --------------- | ------------- | --------------------------------- |
| VyOS Router     | VyOS          | Purpose-built network OS          |
| Gaming Server   | Bazzite       | Purpose-built immutable gaming OS |
| GPU Workstation | Fedora        | NVIDIA driver complexity          |
| K8s Nodes       | Talos         | Purpose-built for Kubernetes      |
| Proxmox Hosts   | Debian        | Too risky, minimal benefit        |
| Smith LXCs      | Fedora/Debian | Storage infrastructure, stable    |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              WORKSTATION                                     │
│                                                                              │
│  $ nix develop          ← Enter reproducible shell (replaces Docker)        │
│  $ task tofu:plan       ← Taskfile still works                              │
│  $ task nix:deploy -- adguard  ← Deploy NixOS config                        │
│                                                                              │
│  flake.nix              ← Single source of truth for tools + hosts          │
│  flake.lock             ← Pinned versions (reproducibility)                 │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              │ SSH (nixos-rebuild --target-host)
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NIXOS FOUNDATIONAL LAYER                             │
│                                                                              │
│   Oracle:                    Niobe:                    Trinity:              │
│   ├── adguard.nix ✅         ├── monitoring.nix        ├── dev.nix          │
│   ├── ids-stack.nix ✅       │   ├── Prometheus        │   └── Coder        │
│   │   └── Zeek               │   ├── Grafana           │                    │
│   │                          │   ├── Loki              ├── media.nix        │
│   ├── gateway.nix            │   └── OTEL              │   ├── Jellyfin     │
│   │   ├── Caddy              │                         │   └── qBit+VPN     │
│   │   ├── Tailscale          └── iot.nix               │                    │
│   │   └── HAProxy                └── Home Assistant    │                    │
│   │                                                                          │
│   ├── keycloak.nix (LXC)                                                    │
│   ├── step-ca.nix (LXC)                                                     │
│   └── openbao.nix (LXC)                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
              trusts (OIDC, certs, secrets)
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    KUBERNETES + OTHER WORKLOADS                              │
│   Talos K8s, VyOS, GPU Workstation, Gaming Server                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
aether/
├── flake.nix                     # Flake root (dev shell + host configs)
├── flake.lock                    # Pinned dependencies
├── nix/
│   ├── hosts/                    # Per-host configurations
│   │   └── oracle/
│   │       ├── adguard.nix       # DNS server (LXC)
│   │       └── ids-stack.nix     # Network security (VM)
│   ├── modules/                  # Reusable modules
│   │   ├── base.nix              # SSH CA, users, firewall, common packages
│   │   ├── otel-agent.nix        # OTEL Collector with Prometheus scraping
│   │   ├── vm-common.nix         # cloud-init, qemu-guest-agent
│   │   └── vm-hardware.nix       # Boot/filesystem for nixos-rebuild
│   └── images/                   # Base images for Proxmox
│       ├── vm-base.nix           # qcow2 image (cloud-init enabled)
│       └── lxc-base.nix          # Proxmox LXC template
│
├── ansible/                      # Remaining (VyOS, GPU Workstation, Proxmox hosts)
├── tofu/                         # VM/LXC provisioning (unchanged)
└── ...
```

## Dev Shell

The Nix flake provides a reproducible CLI environment with all infrastructure tools:

```bash
# Enter dev shell (or auto-enter via direnv)
nix develop

# Tools are available directly
task tofu:plan
task ansible:playbook -- ...
```

With `direnv`, the shell auto-activates when entering the project:

```bash
$ cd ~/projects/aether
direnv: loading .envrc
direnv: using flake
# Tools available automatically in every terminal tab
```

| Aspect          | Docker Toolbox     | nix develop       |
| --------------- | ------------------ | ----------------- |
| Startup time    | Container spin-up  | Instant (cached)  |
| SSH agent       | Volume mount dance | Just works        |
| Tool versions   | Dockerfile         | flake.lock        |
| Disk usage      | ~500MB image       | Shared /nix/store |
| Host dependency | Docker daemon      | Nix only          |

## Base Images

Build VM and LXC templates with SSH CA trust baked in:

```bash
# Build qcow2 for Proxmox VMs (cloud-init enabled)
SSH_CA_PUBKEY="$(ssh root@step-ca cat /etc/step-ca/certs/ssh_user_ca_key.pub)" \
  nix build .#vm-base-image --impure

# Build Proxmox LXC template
SSH_CA_PUBKEY="..." nix build .#lxc-base-image --impure
```

## Deployment

Deploy NixOS configurations to running VMs/LXCs:

```bash
# Deploy to target host
SSH_CA_PUBKEY="$(ssh root@step-ca cat /etc/step-ca/certs/ssh_user_ca_key.pub)" \
  nixos-rebuild switch --flake .#adguard --target-host root@adguard --impure
```

## Migration Progress

| Phase | Target                    | Status      | Notes                                  |
| ----- | ------------------------- | ----------- | -------------------------------------- |
| 1     | Dev shell (`nix develop`) | ✅ Complete | Replaced Docker toolbox                |
| 2     | AdGuard LXC               | ✅ Complete | Full DNS config, OTEL, Prometheus      |
| 3     | IDS Stack VM              | ✅ Complete | Zeek via quadlet-nix, Suricata on VyOS |
| 4     | Gateway Stack             | Planned     | Caddy, Tailscale, HAProxy              |
| 5     | Identity Stack (LXCs)     | Planned     | Keycloak, step-ca, OpenBao             |
| 6     | Monitoring Stack          | Planned     | Prometheus, Grafana, Loki, Tempo       |
| 7     | Remaining VMs             | Backlog     | IoT, Media, Dev Workstation            |

Each phase is independent. Ansible remains for non-NixOS targets indefinitely.

## Secrets Management

| Scope           | Tool                                                     |
| --------------- | -------------------------------------------------------- |
| NixOS VMs/LXCs  | sops-nix (age-encrypted in repo, decrypts at activation) |
| K8s workloads   | OpenBao                                                  |
| Ansible targets | SOPS (existing flow)                                     |

sops-nix integrates seamlessly—secrets decrypt at activation time and never touch the Nix store.

## Comparison

| Aspect               | Ansible + Fedora        | NixOS                             |
| -------------------- | ----------------------- | --------------------------------- |
| Drift                | Possible between runs   | Impossible—config IS state        |
| Rollback             | PBS snapshot or re-run  | `nixos-rebuild --rollback`        |
| Reproducibility      | Best effort             | Guaranteed (flake.lock)           |
| Partial failures     | Service half-configured | Atomic—all or nothing             |
| Container management | podman_pod/podman_container module | quadlet-nix (declarative systemd) |

## Related Documents

- [Virtual Machines](virtual-machines.md) — VM/LXC allocation
- [Trust Model](trust-model.md) — Identity architecture
- [Secrets](secrets.md) — Encryption key hierarchy
- [exploration/nixos.md](exploration/nixos.md) — Detailed technical exploration
