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
| Observability | Kubernetes Grafana and HyperDX (ClickStack), ClickHouse metrics/logs/traces, Zeek, Suricata, Fleet, OpenTelemetry |
| Runtime security | Suricata, Zeek, CrowdSec, Tetragon, Trivy Operator, Policy Reporter, Kyverno |
| AI and GPU | llama-swap, LiteLLM, OpenWebUI, ComfyUI, Docling, Speaches, Jupyter |
| Applications | GitLab, Matrix, Home Assistant, Z-Wave, Matter, Jellyfin, AIOMetadata, Remux (evaluation), Sunshine, Nextcloud, Immich |
| Cloud | AWS, Google Cloud, Cloudflare — public ingress, SES, identity federation, uptime monitoring, budgets, offsite backup |
| Automation | OpenTofu, Ansible, NixOS, Talos, go-task, GitLab CI/CD |

ClickHouse is the telemetry query store; Grafana dashboards and alerts use SQL.
Prometheus and Loki still receive dual-written copies and supply historical
backfills only; they are scheduled for removal after backfill completion. See
[Monitoring](docs/monitoring.md) for storage, retention, and tenant isolation.

## Getting Started

[Nix](https://nixos.org/) is the only host dependency — the flake pins
OpenTofu, Ansible, SOPS, OpenBao, the AWS and Google CLIs, `kubectl`,
`talosctl`, Helm, Babashka, go-task, and the rest of the toolchain.

```bash
nix develop        # enter the pinned toolchain (direnv may do this automatically)
task login:status  # check cached credentials
task login         # Keycloak device auth -> AWS, Google WIF, OpenBao, Ceph RGW, OCI, SSH certificate
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

### Orion Release And Ownership Handover

Orion's chart owns only Deployment/Service `orion` in namespace `orion` and
Agents `orion`, `coordinator`, and the eight `orion-feed-*` topic Agents in
`org-personal`. Aether retains `dev`, `notes-keeper`, namespaces, Secrets,
static MCP credentials, PVCs, CNPG/backups, egress, HTTPRoute, QA browser,
Keycloak, Cedar and CRDs. Dev retains the shared gateway authentication,
ask policy and ClickStack tool list in Aether. Do not use old direct-Agent
patch/apply recipes.
The production chart must not override `agents` in `orion_chart_values.json`;
Agent definitions ship with Orion. Capture only non-secret workload settings,
including allocated Service addresses and admission defaults.

All commands here run from the Aether root inside `nix develop --command`.
Check credentials with `nix develop --command task login:status`, and verify
`nix develop --command kubectl config current-context` prints
`admin@aether-k8s` before any cluster or Helm access. Never force-unlock state.
The commands describe an operator-reviewed procedure, not an automatic deploy.

#### First Adoption Only

Do not apply the handover patch until the disposable adoption proof passed,
service authorization is deployed, and rendered/live parity covers all twelve
objects with the actual intended image SHA. Replace `<RECAPTURE_SHA>` with
the full 40-character SHA whose same-SHA main image and chart were published
and whose image was deployed through the legacy Deployment before adoption.
The current deployed `d13849f22cb7e16d9abff4a5a33ea5255e468d0e` does not
contain the refreshed chart. Gate/push a new release, deploy its image first,
recapture workload values and require `check.sh --live` at that new image tag.
Never overwrite an immutable old chart tag or adopt with a different image
merely to make the chart pull succeed. Never apply with the placeholder pin.

Before removing the legacy resource definitions, stage ownership in those
existing definitions and apply a separately reviewed annotation-only plan:

- Merge `app.kubernetes.io/managed-by = Helm` into resource metadata labels.
- Merge `meta.helm.sh/release-name = orion` and
  `meta.helm.sh/release-namespace = orion` into resource metadata annotations.
- Apply this to the Deployment, Service, both core Agents and every feed
  for_each instance. Never add it to pod metadata or Agent specs; do not adopt
  the default ServiceAccount. The Agent release namespace annotation is
  `orion`, even though those Agents live in `org-personal`.

While all five legacy resource definitions still exist (before applying
the handover patch), save and review the ownership plan:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu plan -input=false -lock-timeout=120s -target=module.home.module.kubernetes.kubernetes_deployment_v1.orion -target=module.home.module.kubernetes.kubernetes_service_v1.orion -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_coordinator_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_feed_agent -out=/tmp/orion-ownership.plan'
nix develop --command bash -c 'tofu -chdir=tofu show -json /tmp/orion-ownership.plan | jq -r ".resource_changes[] | select(.change.actions != [\"no-op\"]) | [.address, (.change.actions|join(\",\"))] | @tsv"'
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu apply -input=false /tmp/orion-ownership.plan'
```

The apply command is conditional on review and explicit approval, never run
as an unattended three-command chain.

Review its JSON: only twelve metadata updates are allowed; no spec changes, pod rollout,
Agent revision changes, creates or deletes. Capture uid before this stage;
then capture uid/resourceVersion/generation/spec, pod identity/imageID/restart
count, Agent revision hashes, and active Orion/coordinator session identities
after annotation settlement. Preserve a secure state backup outside git.
Only then install the handover patch (the removed blocks are migration
history, not destroy instructions), and save the handover plan:

```bash
nix develop --command bash -c 'umask 077; mkdir -p /tmp/orion-adoption; export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu plan -input=false -lock-timeout=120s -target=module.home.module.kubernetes.kubernetes_deployment_v1.orion -target=module.home.module.kubernetes.kubernetes_service_v1.orion -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_coordinator_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_feed_agent -target=module.home.module.kubernetes.helm_release.orion -out=/tmp/orion-adoption/handover.plan'
nix develop --command bash -c 'umask 077; tofu -chdir=tofu show -json /tmp/orion-adoption/handover.plan > /tmp/orion-adoption/handover.json; jq -r '\''.resource_changes[] | select(.change.actions != ["no-op"]) | [.address, (.change.actions|join(","))] | @tsv'\'' /tmp/orion-adoption/handover.json'
```

Require exactly twelve `forget` actions (Deployment, Service, two core Agents,
eight feed instances) and one `helm_release.orion` create. All other
resources must be no-op: no delete, replacement, or unrelated update. Target
the whole feed resource, not just a selected topic. Recheck actual-release
render/live parity immediately before the explicitly approved apply:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu apply -input=false /tmp/orion-adoption/handover.plan'
```

Compare all before/after identities/specs and revision hashes; explain any
status-only resourceVersion change rather than accepting a spec change.
Require unchanged Service uid/addresses and Deployment pod uid, ReplicaSet
hash, imageID and restart count, and replies in the same pre-existing Orion
and coordinator sessions. Smoke Home/Notes, service identity/policy denials,
and a natural nested feed schedule/ingestion. No handover rollout or Agent
revision is expected. The first release is deliberately `atomic=false` and
`cleanup_on_fail=false`: on failure, inspect and repair retained objects and
state; do not uninstall, force-update, replace, use take-ownership, run state
rm, or recreate old Tofu owners. After successful adoption, set `atomic=true`
in a separately reviewed release-metadata-only apply; keep
`cleanup_on_fail=false`. Keep removed blocks until every state consumer has
crossed the migration.

#### Ordinary Releases After Adoption

1. In Orion, run the existing Coder gate at the reviewed commit (no local Mac
   Node/npm), then fast-forward push that commit to `main` and `dev/revamp`.
   A non-fast-forward refusal is a stop, not permission to force-push.
2. Require successful image-build, chart-check and chart-publish for the same
   full lowercase 40-character SHA. Authenticate and pull both immutable
   artifacts: image `registry.gitlab.home.shdr.ch/so/orion/main:<sha>` and
   chart `oci://registry.gitlab.home.shdr.ch/so/orion/charts/orion` version
   `0.1.0-g<sha>`. Helm uses the existing local registry credentials. If the
   locked provider cannot resolve OCI, stop and prove the fix on disposable
   resources; do not switch production to a local chart path.
3. Obtain explicit approval for the existing `orion-prepull` DaemonSet
   create/delete recipe in Orion's deploy documentation. Pre-pull the chosen
   image on nodes using `orion-gitlab-registry`, wait for readiness, then
   remove the preparation DaemonSet after rollout. If the release contains
   migrations, take the required Barman backup before deployment.
4. Change only `orion_release` in
   `tofu/home/kubernetes/orion_release.tf`; chart version and image tag derive
   from it. Save the targeted plan and inspect its JSON before applying:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu plan -input=false -lock-timeout=120s -target=module.home.module.kubernetes.helm_release.orion -out=/tmp/orion-release.plan'
nix develop --command bash -c 'tofu -chdir=tofu show -json /tmp/orion-release.plan | jq -r ".resource_changes[] | select(.change.actions != [\"no-op\"]) | [.address, (.change.actions|join(\",\"))] | @tsv"'
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu apply -input=false /tmp/orion-release.plan'
```

Allow only the release's in-place update and explicitly reviewed dependencies;
reject unrelated changes. Run rollout, Agent/revision and existing-session
smoke checks. Image changes intentionally cause one Recreate rollout; a
chart-only no-op must not roll pods or revise Agents. Aether Secret-only
changes remain Aether changes and intentionally update `envChecksum`, which
can restart Orion. No release/checksum metadata is added to pod templates or
Agent specs beyond the existing environment checksum.

An explicitly approved `nix develop --command helm rollback orion <revision>
-n orion --wait` rolls back app and Agents together. Pin the corresponding
rollback SHA in Aether before the next apply; Helm rollback alone does not
update the declared release pin. First-install failure is not a rollback to
legacy Tofu owners and must never be handled by uninstall/reinstall.

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
| [Naming Ontology](docs/naming.md) | Fabric, site, host, service, and topology identity |
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
