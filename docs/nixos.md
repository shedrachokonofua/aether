# NixOS

NixOS is the preferred target OS for suitable long-lived Aether VMs and LXCs.
OpenTofu or Ansible still provisions the Proxmox guest; Nix declares the guest OS
and service configuration.

## Direction

Move most long-lived Fedora service VMs/LXCs to NixOS over time. Do not describe
a service as migrated until all of these exist:

1. A host configuration under `nix/hosts/`
2. An exposed `nixosConfigurations` entry in `flake.nix`
3. A reproducible provisioning and Taskfile deployment path
4. Secret and monitoring integration
5. Live verification after deployment

Until then, the current Tofu/Ansible path remains authoritative. NixOS migration
does not imply removing Ansible where it still owns provisioning or integration.

## Tool Responsibilities

| Concern | Current owner |
| --- | --- |
| Reproducible CLI environment | `flake.nix`, `flake.lock`, `nix develop` |
| VM/LXC provisioning | OpenTofu or the existing Ansible provisioning playbook |
| NixOS configuration | `nix/hosts/`, `nix/modules/`, `flake.nix` |
| Multi-step deployment | `Taskfile.yml` `_nixos-deploy` and public configure/deploy targets |
| Containers on NixOS | Podman/Quadlet where the host configuration declares them |
| NixOS secrets | OpenBao agent and/or sops-nix as declared by the host modules |
| Kubernetes secrets | OpenBao/Kubernetes resources declared by Tofu |
| Non-NixOS systems | Their established Ansible, Tofu, VyOS, Talos, or Proxmox path |

## Current NixOS Coverage

`flake.nix` currently exposes five deployable configurations:

| Flake target | Placement | Taskfile path |
| --- | --- | --- |
| `adguard` | Oracle LXC | `task configure:adguard` / `task deploy:adguard` |
| `adguard-secondary` | Trinity LXC | `task configure:adguard-secondary` / `task deploy:adguard-secondary` |
| `bastion` | Oracle LXC | `task configure:bastion` / `task deploy:bastion` |
| `ids-stack` | Oracle VM | `task configure:ids-stack` / `task deploy:ids-stack` |
| `blockchain-stack` | Smith VM | `task configure:blockchain-stack` / `task deploy:blockchain-stack` |

Verify the list rather than relying on this table:

```bash
nix develop -c nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r '.[]'
```

Files under `nix/hosts/` that are not exposed by `flake.nix` and lack a Taskfile
path are work in progress, not deployable coverage.

## Migration Candidates

The established direction is to migrate suitable Fedora services, including the
gateway, monitoring, and identity stacks. Other long-lived Fedora VMs should be
assessed using the same pattern. This is a target architecture, not a committed
order or statement of current runtime.

Keep purpose-built platforms on their established OS unless the IaC explicitly
changes:

- VyOS router
- Talos Kubernetes nodes
- Proxmox hosts
- Bazzite build/gaming workflows

Storage and hardware-sensitive guests require case-by-case migration plans.

## Repository Layout

```text
flake.nix                         dev shell and exposed NixOS configurations
flake.lock                        pinned inputs
nix/images/                       Proxmox VM/LXC base images
nix/hosts/common/                 shared host configuration
nix/hosts/oracle/                 AdGuard, bastion, and IDS configurations
nix/hosts/trinity/                secondary AdGuard configuration
nix/hosts/smith/                  blockchain and in-progress storage configs
nix/modules/                      base, VM, OTel, OpenBao, osquery, and secret modules
config/vm.yml                     shared placement, sizing, address, and port facts
Taskfile.yml                      supported build, provision, configure, and deploy flows
```

## Images

Build and upload the repository base images through Taskfile targets:

```bash
task nix:build-vm-image
task nix:upload-vm-image
task nix:build-lxc-image
task nix:upload-lxc-image
```

## Deployment

Use the target-specific Taskfile workflow, not a raw copied
`nixos-rebuild --target-host` command. `_nixos-deploy` obtains the SSH CA key,
rsyncs the repository without secrets/generated state, and runs the build on the
Linux target so deployment works from macOS.

```bash
task login:status
task configure:adguard
task configure:bastion
task configure:ids-stack
```

Use `task deploy:<target>` only when both provisioning and configuration are
intended. Check `task --list-all` for the current supported targets.

## Migration Definition of Done

- Guest provisioning is reproducible from the current checkout.
- The flake evaluation and target build succeed.
- Secrets render without entering the Nix store.
- SSH CA trust, OTel, and Fleet/osquery coverage are present where applicable.
- Service data and rollback paths are documented and tested.
- DNS, proxy, identity, storage, and backup dependencies still work.
- The old Fedora guest/path is removed only after live verification.
- `docs/`, inventory, Taskfile targets, and obsolete Ansible ownership are updated.

## Related Documents

- [Virtual Machines](virtual-machines.md)
- [Monitoring](monitoring.md)
- [Trust Model](trust-model.md)
- [Secrets](secrets.md)
- [NixOS exploration](exploration/nixos.md) for historical design context
