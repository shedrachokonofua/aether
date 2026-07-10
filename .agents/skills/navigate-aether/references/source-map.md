# Aether Source Map

Use docs to learn intent and vocabulary. Use the authoritative paths to decide what the repo declares.

| Question | Read first | Verify in |
| --- | --- | --- |
| Overall topology and workflows | `README.md`, `docs/nixos.md` | `flake.nix`, `flake.lock`, `Taskfile.yml`, repo roots |
| Physical hardware | `docs/hosts.md` | `ansible/inventory/hosts.yml`; live Proxmox/Talos for current status |
| VM/LXC placement and sizing | `docs/virtual-machines.md` | `config/vm.yml`, `tofu/home/*.tf`, provisioning playbooks |
| Talos cluster | `docs/paas.md` | `tofu/home/talos_cluster.tf`, Talos entries in `config/vm.yml` |
| Kubernetes platform and apps | `docs/paas.md` | `tofu/home/kubernetes/*.tf` |
| Namespace governance | `docs/namespace-strategy.md` | `tofu/home/kubernetes/namespaces.tf`, `namespace_contracts.tf`, Kyverno resources |
| Network, VLAN, DNS, edge | `docs/networking.md` | `ansible/playbooks/home_router/`, gateway Caddy, Nix AdGuard, `tofu/cloudflare.tf` |
| Tailscale | `docs/tailscale.md` | `tofu/tailscale.tf`, gateway/public-gateway playbooks |
| Storage and Ceph | `docs/storage.md`, `docs/ceph-implementation.md` | storage playbooks, `tofu/home/kubernetes/*ceph*`, live Ceph |
| Backups | `docs/backups.md` | backup playbooks, `tofu/aws/offsite-backup.tf`, Kubernetes backup resources, SeaweedFS config |
| Monitoring and security telemetry | `docs/monitoring.md` | `ansible/playbooks/monitoring_stack/`, monitoring roles, Kubernetes OTel/security resources |
| Automated alert investigation (Inquest) | `../inquest/README.md`, `../inquest/docs/operator.md` | Flow behavior and state in `../inquest/flows/`, `../inquest/tofu/main.tf`; platform integration in `tofu/home/kubernetes/kestra.tf`, `tofu/home/kubernetes/holmesgpt.tf`, `ansible/playbooks/monitoring_stack/grafana/provisioning/alerting/contact-points.yml.j2`, and `tofu/home/openbao_so_ci.tf` |
| Identity and trust | `docs/trust-model.md`, `docs/secrets.md` | Keycloak/OpenBao Tofu, step-ca/Keycloak/OpenBao playbooks, `.sops.yaml` |
| NixOS systems | `docs/nixos.md` | `flake.nix` `nixosConfigurations`, `nix/hosts/`, `nix/modules/`, Taskfile deploy targets |
| AWS | `docs/aws.md` | `tofu/aws/*.tf` |
| Google Cloud | `docs/google-cloud.md` | `tofu/google/*.tf`, root `tofu/main.tf` module wiring |
| Cloudflare | `docs/cloudflare.md` | `tofu/cloudflare.tf` |
| AI/GPU services | `docs/ai-ml.md` | matching `tofu/home/kubernetes/*.tf`, GPU node declarations in `config/vm.yml` |
| Communications | `docs/communication.md` | Kubernetes Matrix resources, notifications playbooks/Tofu, AWS SES |

## Authoritative Roots

| Path | Ownership |
| --- | --- |
| `config/vm.yml` | Shared VM/LXC/Talos facts such as names, placement, sizing, addresses, and ports |
| `ansible/inventory/hosts.yml` | SSH inventory and host grouping; it resolves many values from shared facts |
| `tofu/main.tf` | Root state and module wiring for AWS, conditionally instantiated Google Cloud, and home infrastructure |
| `tofu/home/*.tf` | Proxmox, Talos, Keycloak, OpenBao, and home-layer resources |
| `tofu/home/kubernetes/*.tf` | Kubernetes platform and application resources |
| `tofu/aws/*.tf`, `tofu/google/*.tf` | Cloud-specific resources |
| `tofu/cloudflare.tf`, `tofu/tailscale.tf` | Root Cloudflare and Tailscale resources |
| `ansible/playbooks/`, `ansible/roles/` | Host and service configuration still owned by Ansible |
| `nix/hosts/`, `nix/modules/` | Declarative NixOS host and reusable module configuration |
| `flake.nix` | Dev-shell tools and exposed NixOS configurations |
| `Taskfile.yml` | Supported compound workflows and environment setup |
| `.sops.yaml`, `secrets/secrets.yml` | Encrypted secret declarations; never print values |

## Non-authoritative Material

- `docs/exploration/`: design exploration and historical analysis.
- `docs/worklogs/`: point-in-time implementation records.
- `docs/todos.md`: planned work, not deployed state.
- `docs/backup-strategy-brief.md`: strategy and rollout context; confirm current backup code.
- `*.tfplan`, `.terraform/`, `tofu/home/secrets/`, `secrets/tf-outputs.json`: saved, generated, cached, or derived artifacts.

If a doc and code disagree, state the conflict and follow code. If code and live state disagree, describe the drift rather than silently choosing one.
