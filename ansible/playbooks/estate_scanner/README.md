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

`discover` accepts and detaches (`setsid`); `worker discover` performs the scan
and writes `estate_scan.*` in ClickHouse. Deploy the writer password with:

```bash
task configure:estate-scan-schema          # CH schema + estate_scan user/role
task configure:estate-scanner-credentials  # password file on the guest
```