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

| Target           | Current               | Becomes       | Why NixOS                                 |
| ---------------- | --------------------- | ------------- | ----------------------------------------- |
| CLI Toolbox      | Docker container      | `nix develop` | No container overhead, native shell       |
| AdGuard          | Part of Gateway Stack | NixOS LXC     | DNS for everything, must be reliable      |
| Network Security | Planned               | NixOS VM      | Greenfield, declarative IDS/scanning      |
| Gateway Stack    | Fedora + Ansible      | NixOS VM      | Ingress for everything, needs reliability |
| Monitoring Stack | Fedora + Ansible      | NixOS VM      | Must survive other failures               |
| Identity Stack   | LXCs (Fedora)         | NixOS LXCs    | Critical PKI, secrets, identity           |
| Dev Workstation  | Fedora + Ansible      | NixOS VM      | Reproducible dev environment              |

### What Stays As-Is

| Target          | OS            | Why Not NixOS                     |
| --------------- | ------------- | --------------------------------- |
| VyOS Router     | VyOS          | Purpose-built network OS          |
| Gaming Server   | Bazzite       | Purpose-built immutable gaming OS |
| GPU Workstation | Fedora        | NVIDIA driver complexity          |
| K8s Nodes       | Talos         | Purpose-built for Kubernetes      |
| Proxmox Hosts   | Debian        | Too risky, minimal benefit        |
| Smith LXCs      | Alpine/Debian | Storage infrastructure, stable    |

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
│   ├── adguard.nix            ├── monitoring.nix        ├── dev.nix          │
│   ├── network-security.nix   │   ├── Prometheus        │   └── Coder        │
│   │   ├── Suricata           │   ├── Grafana           │                    │
│   │   └── Nuclei             │   ├── Loki              ├── media.nix        │
│   │                          │   └── OTEL              │   ├── Jellyfin     │
│   ├── gateway.nix            │                         │   └── qBit+VPN     │
│   │   ├── Caddy              └── iot.nix               │                    │
│   │   ├── Tailscale              └── Home Assistant    │                    │
│   │   └── HAProxy                                      │                    │
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
├── nix/
│   ├── flake.nix                 # Flake root (dev shell + host configs)
│   ├── flake.lock                # Pinned dependencies
│   ├── hosts/                    # Per-host configurations
│   │   └── oracle/
│   │       ├── adguard.nix
│   │       └── network-security.nix
│   ├── modules/                  # Reusable modules
│   │   ├── base.nix              # Common config (users, SSH, OTEL)
│   │   └── podman.nix            # quadlet-nix defaults
│   └── shells/
│       └── default.nix           # Dev environment (replaces Docker toolbox)
│
├── ansible/                      # Remaining (VyOS, GPU Workstation, Proxmox hosts)
├── tofu/                         # VM/LXC provisioning (unchanged)
└── ...
```

## Phase 1: Dev Shell (Replaces Docker Toolbox)

The first step is replacing the Docker-based toolbox with `nix develop`. This provides immediate value with zero risk to production systems.

### Current Flow

```bash
# Build container
task build-tools

# Run tools inside Docker
task tofu:plan    # docker run ... tofu plan
task ansible:playbook -- ...  # docker run ... ansible-playbook
```

### New Flow

```bash
# Enter dev shell (or auto-enter via direnv)
nix develop

# Run tools natively
task tofu:plan    # just runs tofu
task ansible:playbook -- ...  # just runs ansible
```

### Benefits

| Aspect          | Docker Toolbox     | nix develop       |
| --------------- | ------------------ | ----------------- |
| Startup time    | Container spin-up  | Instant (cached)  |
| SSH agent       | Volume mount dance | Just works        |
| Tool versions   | Dockerfile         | flake.lock        |
| Disk usage      | ~500MB image       | Shared /nix/store |
| Host dependency | Docker daemon      | Nix only          |

### Ergonomics

With `direnv` + `nix-direnv`, the shell auto-activates when entering the project:

```bash
$ cd ~/projects/aether
direnv: loading .envrc
direnv: using flake
# Tools available automatically in every terminal tab
```

## Migration Path

| Phase | Target                    | Risk           | Effort |
| ----- | ------------------------- | -------------- | ------ |
| 1     | Dev shell (`nix develop`) | None           | Low    |
| 2     | AdGuard LXC               | Low            | Medium |
| 3     | Network Security VM       | Low            | Medium |
| 4     | Gateway Stack             | Medium         | High   |
| 5     | Identity Stack (LXCs)     | Medium         | High   |
| 6     | Monitoring Stack          | Medium         | High   |
| 7     | Remaining VMs             | Lower priority | —      |

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
| Container management | docker_container module | quadlet-nix (declarative systemd) |

## Related Documents

- [Virtual Machines](virtual-machines.md) — VM/LXC allocation
- [Trust Model](trust-model.md) — Identity architecture
- [Secrets](secrets.md) — Encryption key hierarchy
- [exploration/nixos.md](exploration/nixos.md) — Detailed technical exploration
