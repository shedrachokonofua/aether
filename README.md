# Aether

Infrastructure as code for a private cloud spanning a Proxmox home cluster,
bare-metal ARM nodes, Talos Kubernetes, AWS, Google Cloud, Cloudflare, and
Tailscale.

<img src="docs/rack.jpg" alt="Home server rack" width="400">

- [Topology](#topology)
- [Features](#features)
- [Getting Started](#getting-started)
- [Repository Layout](#repository-layout)
- [Common Workflows](#common-workflows)
- [Documentation](#documentation)

## Topology

- **Proxmox VE cluster** — five x86 hosts: `trinity` and `niobe` (compute),
  `neo` (GPU compute), `smith` (bulk storage + GPU), `oracle` (core
  infrastructure and edge).
- **Talos Kubernetes** — control-plane VMs on `trinity`, `neo`, and `niobe`, a
  worker VM on `smith`, and four bare-metal Raspberry Pi workers: `mouse`,
  `dozer`, `tank`, `sparks`.
- **GPUs** — RTX Pro 6000 on `neo` and GTX 1660 Super on `smith`, passed
  through to their Talos VMs.

Details in [Hosts](docs/hosts.md); VM placement in
[`config/vm.yml`](config/vm.yml).

## Features

| Area | Components |
| --- | --- |
| Kubernetes | Cilium, Gateway API, Istio Ambient, vcluster, wasmCloud, CloudNativePG, Ceph and NFS CSI, Kyverno, External Secrets |
| Network and edge | VyOS, VLANs, Tailscale, AdGuard, Caddy home gateway, Cloudflare, AWS Lightsail, CrowdSec |
| Storage and backup | ZFS, Ceph (RBD, CephFS, RGW), NFS, SMB, Proxmox Backup Server, Restic, Backrest, versioned S3, Glacier Deep Archive |
| Identity and secrets | Keycloak SSO, step-ca, mTLS, SSH certificates, OpenBao, SOPS, AWS KMS, offline Age recovery key |
| Observability | Grafana, Prometheus, Loki, Tempo, ClickHouse, Zeek, Suricata, Fleet, OpenTelemetry |
| Runtime security | Suricata, Zeek, CrowdSec, Tetragon, Trivy Operator, Policy Reporter, Kyverno, Kepler |
| AI and GPU | llama-swap, LiteLLM, OpenWebUI, ComfyUI, Docling, Speaches, Jupyter |
| Applications | GitLab, Matrix, Home Assistant, Z-Wave, Matter, Jellyfin, Sunshine, Nextcloud, Immich |
| Cloud | AWS, Google Cloud, Cloudflare — public ingress, SES, identity federation, uptime monitoring, budgets, offsite backup |
| Automation | OpenTofu, Ansible, NixOS, Talos, go-task, GitLab CI/CD |

## Getting Started

[Nix](https://nixos.org/) is the only host dependency — the flake pins
OpenTofu, Ansible, SOPS, OpenBao, the AWS and Google CLIs, `kubectl`,
`talosctl`, Helm, Babashka, go-task, and the rest of the toolchain.

```bash
nix develop        # enter the pinned toolchain (direnv may do this automatically)
task login:status  # check cached credentials
task login         # Keycloak device auth -> AWS, Google WIF, OpenBao, Ceph RGW, SSH certificate
task --list-all    # discover supported workflows, including tasks without descriptions
```

- Blank environment with no OpenTofu state yet? `task login` will not work —
  start with [Bootstrap](#bootstrap-blank-environment).
- Read [`AGENTS.md`](AGENTS.md) before making changes: state-lock,
  live-patching, authentication, and shared-repository guardrails live there.

### Kubernetes Context

Verify the exact cluster context before Kubernetes or Talos work:

```bash
kubectl config current-context    # expect: admin@aether-k8s
```

If it is wrong, clear an externally supplied kubeconfig and regenerate Aether's
credentials from OpenTofu state:

```bash
unset KUBECONFIG
task k8s:auth
kubectl config current-context
```

## Repository Layout

| Path | What lives there |
| --- | --- |
| [`config/vm.yml`](config/vm.yml) | Shared VM, LXC, and Talos facts |
| [`tofu/`](tofu) | OpenTofu root; module wiring in [`main.tf`](tofu/main.tf) |
| [`tofu/home/`](tofu/home) | Proxmox, Talos, identity, and home infrastructure |
| [`tofu/home/kubernetes/`](tofu/home/kubernetes) | Kubernetes platform and applications |
| [`tofu/aws/`](tofu/aws), [`tofu/google/`](tofu/google) | AWS and Google Cloud resources |
| [`ansible/`](ansible) | Host and service configuration; inventory at [`inventory/hosts.yml`](ansible/inventory/hosts.yml) |
| [`nix/`](nix) | NixOS hosts and reusable modules |
| [`Taskfile.yml`](Taskfile.yml) | Supported workflows |
| [`.sops.yaml`](.sops.yaml), `secrets/` | Encrypted secret policy and data |
| [`docs/`](docs) | Orientation docs — see [Documentation](#documentation) |

## Common Workflows

- Prefer a `task` target over the underlying command — tasks supply cached
  tokens, generated outputs, inventory settings, and required environment.
- Do not use Ansible `--start-at-task` on secret-dependent playbooks; use the
  playbook's tags so prerequisite secret loaders still run.

### OpenTofu

```bash
task tofu:plan
task tofu:apply
```

- One root state under `tofu/`: home addresses begin with `module.home`,
  Kubernetes addresses with `module.home.module.kubernetes`.
- Even a targeted operation parses all loaded configuration — `-target` does
  not isolate unrelated syntax or provider errors.

### Scoped Configuration

There is deliberately no `configure:all`: gateway, monitoring, GitLab, backup,
identity, and other subsystems have independent failure domains and are
changed one at a time.

```bash
# Ansible-managed hosts and services
task configure:gateway
task configure:monitoring
task configure:backup
task configure:keycloak

# NixOS hosts
task configure:adguard
task configure:bastion
task configure:ids-stack
```

### Secrets

```bash
task sv              # view secrets/secrets.yml
task se              # edit secrets/secrets.yml
task sg -- '.path'   # read one value
task sl              # list keys without printing values
task sops:rotate     # rewrap encrypted files with current .sops.yaml recipients
```

- The Age private key is an offline bootstrap and recovery recipient, not a
  day-to-day credential — see [Secrets](docs/secrets.md) for recipients and
  recovery procedures.

### Bootstrap (Blank Environment)

`task login` depends on identity resources and OpenTofu outputs that do not
exist in a blank environment. Bootstrap first, with human AWS administrator
credentials available through the standard environment or profile chain:

```bash
aws sts get-caller-identity   # confirm admin credentials
task bootstrap                # backend CloudFormation stack + config/tofu-state.config + root init
```

- `task bootstrap` only prepares the remote OpenTofu backend; it does not
  provision the rest of Aether.
- The first root apply also needs bootstrap credentials for providers whose
  federated identities do not exist yet — for Google Cloud, a human
  Application Default Credential from `gcloud auth application-default login`.
- After the identity resources are applied and outputs written, switch to
  `task login` for normal keyless access, and provision each subsystem with
  its scoped task.

## Documentation

### Infrastructure

| Doc | Scope |
| --- | --- |
| [Hosts](docs/hosts.md) | Physical hosts and roles |
| [Virtual Machines](docs/virtual-machines.md) | VM/LXC placement and capacity |
| [Networking](docs/networking.md) | VLANs, firewall, DNS, gateways, and routing |
| [Storage](docs/storage.md) | Ceph, ZFS, NFS, SMB, and CephFS |
| [Backups](docs/backups.md) | PBS, database, volume, and offsite backups |
| [PaaS](docs/paas.md) | Talos Kubernetes and platform services |
| [Namespace Strategy](docs/namespace-strategy.md) | Namespace ownership and policy contracts |
| [NixOS](docs/nixos.md) | Declarative systems and migration direction |
| [UPS](docs/ups.md) | Power monitoring and shutdown behavior |

### Operations and Services

| Doc | Scope |
| --- | --- |
| [Monitoring](docs/monitoring.md) | Metrics, logs, traces, dashboards, and alerts |
| [AI/ML](docs/ai-ml.md) | GPU workloads, inference, model routing, and user interfaces |
| [Communication](docs/communication.md) | Matrix, bridges, notifications, and mail relay |
| [GitLab Kubernetes Runner](docs/gitlab-k8s-runner.md) | Runner architecture and operations |
| [Bastion](docs/bastion.md) | Administrative access path |

### Trust and External Systems

| Doc | Scope |
| --- | --- |
| [Trust Model](docs/trust-model.md) | Identity planes and authentication architecture |
| [Secrets](docs/secrets.md) | OpenBao, SOPS, recipients, and recovery |
| [AWS](docs/aws.md) | Public gateway, identity, backups, KMS, SES, and budgets |
| [Google Cloud](docs/google-cloud.md) | Uptime monitoring, identity federation, Maps APIs, and budgets |
| [Cloudflare](docs/cloudflare.md) | DNS and edge configuration |
| [Tailscale](docs/tailscale.md) | Mesh networking and remote access |

[`docs/todos.md`](docs/todos.md), `docs/exploration/`, and `docs/worklogs/`
describe plans or historical work. Confirm their claims against current code
before acting on them.
