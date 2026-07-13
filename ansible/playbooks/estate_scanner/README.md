# Estate scanner guest

Unprivileged NixOS LXC on `neo` for active estate discovery and safe Nuclei
validation. Design: `docs/exploration/estate-scanning.md`.

| Fact | Value |
| --- | --- |
| Name | `estate-scanner` |
| VMID | `1036` |
| Address | `10.0.2.13` (VLAN 2) |
| Size | 2 vCPU / 4 GiB / 1 GiB swap / 32 GiB |
| Provision | Ansible `pct` (not OpenTofu) |
| Dispatcher | Babashka `aether-scan.bb` |

## Commands (after approval)

```bash
task nix:upload-lxc-image   # if the NixOS LXC template is missing
task provision:estate-scanner
task configure:estate-scanner
```

`provision:estate-scanner` requires `-e estate_scanner_provision_approved=true`.

## CAP_NET_RAW gate

After boot, prove Naabu SYN discovery from `10.0.2.13` against a controlled
target. Do **not** set `lxc.cap.keep: net_raw` alone — LXC treats that as an
exclusive allowlist and drops every other capability, so `/sbin/init` exits
immediately. If SYN mode cannot work with the default unprivileged capability
set (or a carefully complete keep-list), replace with a 2 vCPU / 4 GiB VM —
do not privilege the LXC.

## Dispatcher

`aether-scan` is a Babashka script (`aether-scan.bb`) — the only Kestra
entrypoint (`ForceCommand` for `kestra-estate-scanner`). Runtime paths and
allowlists live in `/etc/estate-scanner/runtime.json`. It accepts typed stage
operations and approved profile / target-group names only.

`discover` / `fingerprint` accept and detach (`setsid`); workers write
`estate_scan.*` in ClickHouse. `merge-diff` compares against the prior successful
run and emits `services-changed.jsonl`.

```bash
task configure:estate-scan-schema          # CH schema + estate_scan user/role
task configure:estate-scanner-credentials  # password file on the guest
task configure:estate-scanner              # NixOS (dispatcher + SSH ForceCommand)
task configure:grafana                     # Estate Scan dashboard + stale/failed alerts
```

Calibration groups: `iot`, `gigahub`, `calib-server`, `cidr-infra` (`10.0.2.0/24`).
Grafana dashboard uid `estate-scan`; alerts `estate-scan-run-stale` /
`estate-scan-run-failed`.

Kestra dispatch identity: `kestra-estate-scanner` (pubkey in
`config/ssh/kestra-estate-scanner.pub`; private key in SOPS
`estate_scan.kestra_ssh_private_key`). Flow:
`kestra/flows/estate-scan-home.yaml` (namespace `aether.estate`). Apply via
Kestra API (`POST/PUT /api/v1/main/flows`); secret `kestra-estate-scan`
mounts `ENV_ESTATE_SCANNER_*` + `SECRET_ESTATE_SCANNER_SSH_KEY`.

VyOS path: `SERVICES-to-TRUSTED` rule 26 — source `TALOS-NODES`, destination
`10.0.2.13:22` only (not Proxmox/MGMT; rule 25 remains SeaweedFS). Apply with
`task configure:router-estate-scanner-dispatch`.