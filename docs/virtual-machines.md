# Virtual Machines and LXCs

`config/vm.yml` is the shared source of truth for declared Proxmox guest names,
placement, sizing, addresses, and ports. This document summarizes those
declarations; it does not claim that every guest is currently running.

Verify live status through Proxmox/Prometheus and applied ownership through Tofu
state or the relevant provisioning playbook.

## Service Guests

Memory and disk values below are the declared guest memory and root disk. Storage
services may have additional passthrough devices, datasets, or mount points.

| Config key | Guest | Node | Type | vCPU | Memory | Root disk | Provisioning owner |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `router` | `vyos-router` | Oracle | VM | 8 | 2 GiB | 128 GB | Ansible router playbooks |
| `home_gateway_stack` | `home-gateway-stack` | Oracle | VM | 4 | 4 GiB | 128 GB | `tofu/home/gateway_stack.tf` |
| `monitoring_stack` | `monitoring-stack` | Niobe | VM | 4 | 16 GiB | 256 GB | `tofu/home/monitoring_stack.tf` |
| `nfs` | `network-file-server` | Smith | LXC | 2 | 1 GiB | 10 GB | Ansible network-file-server playbooks |
| `gitlab` | `gitlab` | Trinity | VM | 8 | 8 GiB | 256 GB | `tofu/home/gitlab.tf` |
| `backup_stack` | `backup-stack` | Smith | LXC | 4 | 8 GiB | 20 GB | `tofu/home/backup_stack.tf` |
| `iot_management_stack` | `iot-management-stack` | Niobe | VM | 4 | 2 GiB | 32 GB | `tofu/home/iot_management_stack.tf` |
| `cockpit` | `cockpit` | Niobe | VM | 1 | 1 GiB | 32 GB | `tofu/home/cockpit.tf` |
| `notifications_stack` | `notifications-stack` | Niobe | VM | 2 | 2 GiB | 64 GB | `tofu/home/notifications_stack.tf` |
| `seaweedfs` | `seaweedfs` | Smith | LXC | 4 | 4 GiB | 32 GB | Ansible SeaweedFS provisioning |
| `keycloak` | `keycloak` | Oracle | LXC | 2 | 2 GiB | 32 GB | Ansible Keycloak provisioning |
| `step_ca` | `step-ca` | Oracle | LXC | 2 | 512 MiB | 16 GB | Ansible step-ca provisioning |
| `openbao` | `openbao` | Oracle | LXC | 2 | 512 MiB | 32 GB | Ansible OpenBao provisioning |
| `adguard` | `adguard` | Oracle | LXC | 1 | 1 GiB | 20 GB | Ansible provision, NixOS configure |
| `adguard_secondary` | `adguard-secondary` | Trinity | LXC | 1 | 2 GiB | 20 GB | Ansible provision, NixOS configure |
| `bastion` | `bastion` | Oracle | LXC | 2 | 2 GiB | 32 GB | Ansible provision, NixOS configure |
| `ids_stack` | `intrusion-detection-stack` | Oracle | VM | 4 | 4 GiB | 128 GB | OpenTofu provision, NixOS configure |
| `nix_builder` | `nix-builder` | Neo | VM | 8 | 8 GiB | 128 GB | OpenTofu provision, NixOS configure |
| `blockchain_stack` | `blockchain-stack` | Smith | VM | 8 | 16 GiB | 256 GB | OpenTofu provision, NixOS configure |

## Talos VMs

Four x86 Talos guests join the four bare-metal ARM workers documented in
`docs/hosts.md`.

| Config key | Guest | Proxmox node | Role | vCPU | Memory | Root disk | GPU |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `talos_trinity` | `talos-trinity` | Trinity | control plane | 8 | 32 GiB | 128 GB | - |
| `talos_neo` | `talos-neo` | Neo | control plane | 32 | 64 GiB | 256 GB | RTX Pro 6000 Blackwell |
| `talos_niobe` | `talos-niobe` | Niobe | control plane | 8 | 24 GiB | 128 GB | - |
| `talos_smith` | `talos-smith` | Smith | worker | 12 | 32 GiB | 128 GB | GTX 1660 Super |

These guests are declared by `tofu/home/talos_cluster.tf`; Kubernetes workloads
are declared under `tofu/home/kubernetes/`.

## Temporary Builders

| Config key | Guest | Node | Type | vCPU | Memory | Root disk | Owner |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `vyos_packer` | `vyos-packer` | Oracle | VM | 4 | 4 GiB | 10 GB | Ansible router image workflow |
| `bazzite_builder` | `bazzite-builder` | Smith | VM | 8 | 4 GiB | 64 GB | Ansible game-server image workflow |

Builders are workflow inputs and should not be treated as long-lived service
capacity without live verification.

## Removed VM Workloads

The old Development Workstation/Coder, Dokploy, media-stack, AI-tool-stack, and
standalone gaming-server VM entries are absent from `config/vm.yml`. Their
retained names in migration comments or legacy playbooks are not current guest
declarations. Current application replacements are primarily under
`tofu/home/kubernetes/`; consult `docs/paas.md` and service-specific IaC.

## Declared Totals

Across the 25 service, Talos, and builder entries summarized above,
`config/vm.yml` declares 143 vCPU, 249,856 MiB of memory, and 2,336 GB of root
disk. These are allocation declarations, not measurements of live usage or
physical headroom.
