# Aether Ownership and Change Paths

This reference identifies where a change belongs. It does not authorize mutation.

## Find Before Acting

```bash
nix develop -c git status --short
nix develop -c task --list-all
nix develop -c rg -n -i '<name|hostname>' config tofu ansible nix Taskfile.yml
```

Use `rg --files` to inspect candidate directories. Check nested `AGENTS.md` files before entering agent-specific subtrees.

## Ownership Matrix

| Change | Start in | Confirm with |
| --- | --- | --- |
| VM/LXC name, placement, size, IP, port | `config/vm.yml` | consuming Tofu/playbook/Nix files |
| Proxmox VM/LXC lifecycle | `tofu/home/*.tf` or provisioning playbook | matching `task provision:*` / `task deploy:*` target |
| Talos node or cluster | `tofu/home/talos_cluster.tf` | `config/vm.yml`, `task k8s:auth` behavior |
| Kubernetes app/platform | `tofu/home/kubernetes/*.tf` | namespace contract, route, secret, storage, backup, monitoring dependencies |
| AWS or Google resource | `tofu/aws/`, `tofu/google/` | root module wiring in `tofu/main.tf` |
| DNS/CDN | `tofu/cloudflare.tf`, AdGuard Nix, router config | intended internal/public resolution path |
| Home/public proxy | gateway/public-gateway Caddy templates | Taskfile configure target and upstream ownership |
| VM service | matching `ansible/playbooks/` and roles | Taskfile shortcut and inventory target |
| NixOS service | matching `nix/hosts/` and `nix/modules/` | exposure in `flake.nix` plus Taskfile deploy target |
| Identity/OIDC | Keycloak Tofu plus deployment playbook | realm/client/flow source and rendered login/API behavior |
| Secret engine/policy | OpenBao Tofu/playbook and SOPS | consumer path; never expose decrypted values |
| Monitoring pipeline | monitoring-stack playbook and agent/Kubernetes OTel config | live Grafana datasource and target state |
| Alert or dashboard | Grafana provisioning under monitoring stack | live read-only Grafana state after deployment |
| Inquest alert flow or incident lifecycle | `../inquest/flows/`, `../inquest/tofu/main.tf` | Aether Kestra/Holmes/Grafana/OpenBao integration plus live Kestra flow state |
| Backup | backup playbooks, AWS backup Tofu, K8s backup resources, Seaweed config | live operation and restore evidence |

## Workflow Facts

- `task login:status` checks cached SSH, OpenBao, AWS, Google WIF, and Ceph S3 access. `task login` is the unified AWS + OpenBao + SSH flow; refresh only the missing/expired access rather than logging in speculatively.
- `task login -- --ssh` is the narrow SSH-certificate refresh when SSH is the only missing access.
- Prefer a Taskfile target when one exists; re-list targets rather than copying a doc command.
- `task tofu:plan` and `task tofu:apply` run from the root state in `tofu/` and load cached Bao/Google credentials.
- `task tofu:apply` also writes `secrets/tf-outputs.json` and runs `task k8s:auth`, which overwrites kubeconfig/talosconfig.
- Run `task k8s:auth` only when the Kubernetes/Talos config is wrong or stale; it overwrites rather than merges local configs.
- Home resource targets use `module.home...`; Kubernetes targets use `module.home.module.kubernetes...`.
- Ansible depends on `ansible/ansible.cfg`; Taskfile sets `ANSIBLE_CONFIG` for supported workflows.
- A Nix file is not deployable merely because it exists. Verify that `flake.nix` exposes the configuration and the Taskfile exposes or documents a deployment path.
- NixOS is the preferred target for suitable long-lived Fedora VM/LXC migrations, but current ownership remains authoritative until each migration is declared, deployable, and verified.
- Inventory may not include every `config/vm.yml` target. Report the missing alias instead of inventing one.
- Inquest flow state uses its own GitLab HTTP backend in
  `../inquest/tofu/main.tf`. Aether's S3/DynamoDB lock and unlock workflow does
  not apply to that state; never reuse an Aether lock command for the sibling
  repo.

## Boundary Checks

Before proposing a change, identify:

1. Which resource is being changed.
2. Which layer creates it.
3. Which layer configures it.
4. Whether the checkout has local WIP in that path.
5. Whether a plan or live inspection is needed to distinguish declared from applied state.
6. Which docs become false if the change lands.
