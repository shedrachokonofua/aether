# Aether Architecture

## Layers

1. **Physical layer:** five Proxmox hosts plus bare-metal ARM Talos workers. `docs/hosts.md` is orientation; inventory and live APIs establish current facts.
2. **Provisioning layer:** the root OpenTofu state wires AWS, conditionally instantiated Google Cloud, and `module.home`. Google Cloud is enabled in the current encrypted configuration. Home includes Proxmox, Talos, Kubernetes, Keycloak, and OpenBao providers.
3. **Host configuration layer:** Ansible configures many Fedora/Debian/VyOS targets; NixOS configures the hosts exposed by `flake.nix`.
4. **Platform layer:** Talos Kubernetes uses Cilium, Gateway API, Ceph CSI, OTel, and other platform controllers declared under `tofu/home/kubernetes/`.
5. **Application layer:** Kubernetes applications, VM/LXC services, and a few cloud services share identity, DNS, storage, and observability.
6. **Edge layer:** AdGuard and VyOS handle internal DNS/routing; home-gateway Caddy fronts internal services; Cloudflare and the public gateway front selected public services; Tailscale joins locations.
7. **Control layer:** Keycloak, step-ca, OpenBao, SOPS, GitLab, and the Taskfile provide identity, secrets, PKI, state, and workflows.
8. **Evidence layer:** Grafana correlates Prometheus, Loki, Tempo, and ClickHouse; Kubernetes, Fleet, SSH, and service APIs provide deeper state.

## OpenTofu Address Shape

The repository uses one root state from `tofu/`:

```text
module.aws...
module.google[0]...
module.home...
module.home.module.kubernetes...
```

Targeted operations still parse all loaded root files. Never assume `-target` isolates syntax or provider configuration.

## Hybrid Ownership

| Component class | Provisioning | Configuration/runtime |
| --- | --- | --- |
| Talos and Kubernetes | OpenTofu | Talos resources plus Kubernetes/Helm/Kubectl providers |
| Monitoring, GitLab, gateway, Cockpit, IoT, notifications | Usually OpenTofu VM | Ansible playbooks and roles |
| Backup stack | OpenTofu LXC | Ansible; Kubernetes and AWS own additional backup surfaces |
| AdGuard | Ansible LXC provisioning | NixOS configuration via Taskfile |
| IDS and blockchain stacks | OpenTofu VM | NixOS configuration via Taskfile |
| Keycloak, OpenBao, step-ca | Ansible server/LXC deployment | OpenTofu owns much logical auth/policy/client configuration |
| Public gateway and uptime monitor | OpenTofu cloud resources | Ansible host/service configuration |
| VyOS router | Ansible provisioning/configuration | VyOS configuration and router-specific playbooks |
| Inquest | Aether owns Kestra, Holmes, Grafana routing, secrets, and network policy | Sibling `../inquest` owns Kestra flow IaC and the GitLab incident lifecycle |

Do not compress a hybrid component into a single owner. A change to its VM size, service config, identity client, DNS record, and alert may belong in five different files.

## Direction of Travel

Prefer NixOS for long-lived Fedora VM/LXC replacements when the service fits the existing Nix model. This is target architecture, not current-state shorthand: report current Ansible/Fedora ownership until `flake.nix`, `nix/hosts/`, Taskfile deployment, and live verification all exist. Keep purpose-built VyOS, Talos, Proxmox, Bazzite, and hardware-sensitive exceptions on their established platforms unless the IaC changes.

## Typical Request Paths

Internal application:

```text
client -> AdGuard/VyOS DNS -> home gateway Caddy -> Kubernetes Gateway or VM/LXC service
```

Public application:

```text
client -> Cloudflare -> public gateway Caddy/CrowdSec -> Tailscale -> home gateway or Kubernetes
```

Telemetry:

```text
VM agents / Kubernetes OTel / host exporters -> central OTel or Prometheus
  -> Prometheus (metrics)
  -> Loki (ordinary logs)
  -> Tempo (traces)
  -> ClickHouse (Zeek and Suricata)
  -> Grafana (dashboards, Explore, alerts)
```

Automated incident intake:

```text
Grafana page-class receiver -> Kestra alert-intake -> GitLab incident issue
  -> Holmes read-only RCA -> issue comment -> human-requested remediation MR
```

This path is owned jointly across Aether and sibling `../inquest`; it is
separate from the human-invoked `$investigate-aether` workflow.

Trace the actual hostname and resource declarations before assuming either path.
