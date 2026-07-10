---
name: navigate-aether
description: Map an Aether component, service, host, or proposed change to its runtime, placement, authoritative IaC, configuration owner, Taskfile workflow, dependencies, observability, and current documentation. Use for architecture questions, locating source files, determining whether something runs in Kubernetes or on a VM/LXC/host/cloud, planning where a change belongs, onboarding to the repo, and resolving conflicts between docs and code. For Inquest, separate the sibling repo's automated alert flows and incident lifecycle from Aether's Kestra, Holmes, Grafana, secret, and network platform ownership. This skill orients; use investigate-aether for live incident evidence.
---

# Navigate Aether

Orient in this private-cloud repository without treating documentation as current state. Code is authoritative; live systems are authoritative only for what is running now.

## Start

1. Read the nearest `AGENTS.md`, including a nested one when working under `hermes/`.
2. Run all commands inside `nix develop` and prefer current `task` targets over copied commands.
3. Check `git status --short` before drawing conclusions from the checkout.
4. Run `task login:status` before provider, secret, cloud, or SSH work. Reuse cached credentials; run unified `task login` only when required access is missing or expired.
5. Read [references/source-map.md](references/source-map.md) to select the authoritative layer.
6. Read [references/architecture.md](references/architecture.md) when placement, request flow, or cross-layer dependencies matter.
7. Read [references/change-paths.md](references/change-paths.md) when identifying the provisioning, configuration, secret, routing, or deployment owner.

## Navigation Workflow

### 1. Locate the component

Search names, hostnames, resource names, image names, and Taskfile targets in authoritative roots first:

```bash
nix develop -c rg -n -i '<component|hostname>' \
  config tofu ansible nix Taskfile.yml flake.nix
```

Exclude `.terraform/`, saved plans, generated `tofu/home/secrets/`, and `secrets/tf-outputs.json` from ownership conclusions. Search `docs/` after locating code.

For Inquest, also search `../inquest/README.md`, `../inquest/docs/operator.md`,
`../inquest/flows/`, `../inquest/tofu/`, and `../inquest/Taskfile.yml`. Treat
Aether's `docs/exploration/agentic-incident-response.md` and the dated status in
Inquest's `DESIGN.md` as historical context, not current flow state.

### 2. Classify the runtime

Assign one or more runtime layers:

- physical Proxmox or bare-metal Talos host
- Proxmox VM or LXC
- Talos Kubernetes workload or platform component
- VyOS router or gateway service
- AWS, Google Cloud, Cloudflare, or Tailscale resource
- logical identity, PKI, secret, storage, or observability configuration

Do not infer Kubernetes merely because a service has a web endpoint. Do not infer absence because a service is missing from Kubernetes or one IaC surface.

### 3. Resolve ownership

Identify these separately because Aether commonly splits them:

- provisioning owner
- OS and service configuration owner
- application/runtime owner
- secret and identity owner
- DNS, proxy, and route owner
- metrics, logs, traces, and alert owner

For OpenTofu addresses, remember that home resources begin under `module.home` and Kubernetes resources under `module.home.module.kubernetes`.

### 4. Use docs as orientation

Open only the docs routed from [references/source-map.md](references/source-map.md). Verify every operational claim against code, current Taskfile targets, or live read-only state. Treat `docs/exploration/`, `docs/worklogs/`, `docs/todos.md`, and strategy briefs as history or intent unless current code confirms them.

### 5. Separate four states

Report each relevant state explicitly:

- **Declared:** present in current IaC/configuration.
- **Checkout:** committed, modified, untracked, generated, or absent locally.
- **Applied:** represented in state or last known deployment output; verify when required.
- **Live:** observed through Kubernetes, service APIs, Proxmox, SSH, or telemetry.

Never use one as proof of another. If the question requires current health or root cause, switch to `$investigate-aether`.

## Output Contract

Return a compact map:

```text
Component:
Runtime and placement:
Orientation docs:
Authoritative declarations:
Provisioning owner:
Configuration owner:
Taskfile entry points:
Dependencies:
Routing and identity:
Observability:
Checkout state:
Live state:
Conflicts or gaps:
```

Call out doc drift with the conflicting code path. Correct drift when the task includes documentation updates and the replacement is verified; otherwise flag it without inventing a replacement.
