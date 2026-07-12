# Oracle PVE 8 → 9 upgrade runbook

Planning artifact. **No mutation performed.** Execute only in an agreed
maintenance window with console/IPMI access to oracle as a fallback.

## Situation

The cluster is mid-way through a rolling Proxmox 8→9 upgrade (`upgrade_pve_8_to_9.yml`,
node order neo→niobe→trinity→smith→**oracle**). Four nodes are on `pve-manager/9.1.4`;
**oracle is the lone straggler on `8.3.0`** (pve-cluster `8.0.10`, kernel 6.8).

Symptom that surfaced it: oracle's pmxcfs logs `RRD update error: unknown/wrong
key pve-node-9.0/*` and `pve-storage-9.0/*` for every PVE-9 peer, ~1.2k lines/s,
because its old RRD schema (`pve2-*`) can't parse the 9.0 status keys. The mixed
8/9 cluster is unsupported; finishing oracle is the fix.

## Why oracle is special (blast radius)

oracle hosts the estate's control plane. A reboot takes all of this down:

| VMID | Guest | Role | Storage | Migration |
| --- | --- | --- | --- | --- |
| 1001 | **router** | VyOS — all routing/firewall + WireGuard fabric | local-lvm 128G | live `--with-local-disks` |
| 1002 | **home-gateway-stack** | ingress bridge (Caddy → internal) | local-lvm 128G | live `--with-local-disks` |
| 1028 | intrusion-detection-stack | Zeek/Suricata IDS | local-lvm 128G | live `--with-local-disks` |
| 1010 | bastion (CT) | jump host | local-lvm 32G | offline |
| 1023 | **keycloak** (CT) | SSO | local-lvm 32G | offline |
| 1025 | **step-ca** (CT) | PKI root/issuer | local (dir) 16G | offline |
| 1026 | **openbao** (CT) | secrets | local-lvm 32G | offline |
| 1027 | adguard (CT) | primary DNS | ceph-vm-disks (shared) | restart-migrate |

**Control-path hazard:** my Ansible/SSH to the whole lab routes through the
`router` VM *on oracle*. If oracle reboots with the router still on it, remote
control is lost mid-upgrade and recovery needs console access. → The router MUST
be live-migrated off oracle first, or the upgrade driven from oracle's console.

## Constraints discovered

- **Local storage everywhere but adguard.** No cheap shared-storage migration;
  VMs need `qm migrate --online --with-local-disks` (copies the 128G disk over
  the network while running), CTs need offline migration (stop→copy→start).
- **CTs cannot live-migrate** (Proxmox limitation) → keycloak/step-ca/openbao/
  bastion take a short downtime (stop, disk copy, start) whichever way we go.
- **Cross-version migration 8→9.** Offline CT migration and `--with-local-disks`
  VM migration from an 8.3 source to a 9.1 target are the supported evacuation
  path during rolling upgrades, but live VM migration 8→9 can hit QEMU
  machine-version friction — validate on the IDS VM (least critical) first.
- **Target capacity:** neo (30G free) + smith (17G free) can absorb oracle's
  ~16–20G of guests; niobe/trinity are too tight. Pin migration targets to
  neo/smith.

## Prerequisites (verify before the window)

1. Fresh PBS backups of all eight oracle guests (`pbs-backups-vm`), restorable.
2. **Console/IPMI access to oracle confirmed working** (the non-negotiable
   fallback if remote control is lost).
3. Cluster quorate and healthy; Ceph `HEALTH_OK` (adguard restart-migration
   depends on it).
4. `pve8to9` preflight on oracle returns `FAILURES: 0` (the playbook gates on
   this; it also auto-fixes RBD keyring / systemd-boot / LVM autoactivation).
5. A quiet window: even evacuated, expect brief blips for the router cutover and
   CT restarts (SSO/secrets/DNS/cert-issuance).

## Network topology (verified) — the router can run off oracle

`vmbr0` is a VLAN-aware trunk (vids 2-4094) on a single physical NIC into the
192.168.2.0/24 switch. The router's WAN (PPPoE on eth0) and LAN VLANs all ride
`vmbr0`. **neo and smith both have `vmbr0` trunked to the same switch**
(`vmbr0v2`/`vmbr0v3` VLAN sub-bridges present), so they carry the same WAN + LAN
L2 — the router is not physically pinned to oracle. Only gap: `vmbr_mirror` (the
IDS SPAN bridge, `bridge-ports none`) exists on oracle only; the router's `net2`
needs it present on the target or the VM won't start (create it, or drop `net2`
— it is just the IDS mirror feed). One item to confirm hands-on: that the ISP
PPPoE VLAN is trunked to the target node's switch port (boot-test proves it).

## Router handling: clone-and-cutover (preferred over live-migrate)

For the router specifically, a cold clone beats live migration in this
cross-version case: clone the disk ahead of time with the router still serving,
boot-test it on neo in isolation, then cut over deterministically — no PVE 8→9
live-migration/QEMU-machine-version risk.

1. Create `vmbr_mirror` on neo (`bridge-ports none`, `ageing_time 0`).
2. `qm clone 1001 <newid> --name router --target neo --full` (ahead of window).
   Set the clone's NIC MACs equal to 1001's (PVE randomizes clones by default)
   so downstream ARP/DHCP/MAC-ACLs stay consistent.
3. Boot-test the clone on an isolated bridge (no WAN/LAN uplink) to confirm it
   boots and VyOS config loads; verify the PPPoE VLAN reaches neo.
4. Cutover in the window: `qm stop 1001` on oracle, then `qm start <newid>` on
   neo. **Never run both** — identical VyOS identity (IPs, WireGuard keys, PPPoE
   creds). Expect ~30-60s outage (PPPoE redial + WireGuard re-handshake).
5. Verify WAN, LAN VLANs, WireGuard fabric, and public ingress from neo's router.
6. After oracle is on PVE 9, **migrate the clone back to oracle** — now a
   9→9 live migration (sub-second, no cross-version risk) — and delete the
   stale VM 1001. This restores the designed topology (control plane
   consolidated on oracle) with no `config/vm.yml` changes. Only leave the
   router on neo (re-home + update vm.yml) if you deliberately want to rebalance
   capacity off oracle — not required by the upgrade.

Other guests still follow the evacuate steps below (live-migrate the remaining
VMs, offline-migrate the CTs), or accept their downtime during oracle's reboot
now that the control path (router on neo) is safe.
## Recommended strategy: evacuate, then upgrade an empty oracle

Minimizes downtime and preserves the remote control path.

1. **Validate migration** on the IDS VM (1028): `qm migrate 1028 neo --online
   --with-local-disks`. If clean, proceed; if 8→9 live migration fails, fall
   back to the full-outage strategy below.
2. **Evacuate VMs live** to neo/smith: home-gateway (1002) → smith, IDS (1028)
   → neo, **router (1001) last** → neo (`--online --with-local-disks`). Expect a
   sub-second network blip at the router cutover; verify LAN + WireGuard + public
   ingress after.
3. **Evacuate CTs** (brief downtime each; do identity together to bound the SSO/
   secrets/PKI outage): `pct migrate <id> <target> --restart`. adguard (1027,
   Ceph) is fast; keycloak/openbao/step-ca/bastion copy local disks. Keep a
   second DNS (adguard-secondary) authoritative during the adguard move.
4. **Confirm oracle is empty** (`pct list`/`qm list`), cluster still quorate.
5. **Upgrade oracle**: `task upgrade:pve -- --limit oracle` (dry-run first:
   `task ansible:playbook -- ./ansible/playbooks/upgrade_pve_8_to_9.yml --limit
   oracle --check`). Playbook does 8.3→8.4 → pve8to9 gate → repo swap
   bookworm→trixie → dist-upgrade → reboot. oracle now holds no guests, so its
   reboot is non-disruptive and the control path (router on neo) survives.
6. **Verify oracle on 9.1**, RRD errors gone (`journalctl -u pve-cluster | grep
   -c 'RRD update error'` → 0), cluster shows all 5 nodes on PVE 9.
7. **Rebalance** guests back to oracle if desired (same migration mechanics,
   now 9→9 so live migration is unrestricted), or leave them where they landed
   and update `config/vm.yml` node assignments to match.

## Alternative strategy: full-outage window (simpler, riskier)

Drive the upgrade from **oracle's console** and accept a full estate outage
(network/DNS/ingress/identity down for the dist-upgrade + reboot, ~20–40 min).
No evacuation, no cross-version migration risk, but everything is dark and any
dist-upgrade stall extends the outage. Only acceptable with hands-on console
access and a real maintenance window.

## Rollback

- Per-guest: if a migration misbehaves, migrate it back (source still intact
  until migration completes) or restore from PBS.
- oracle upgrade: the playbook stops on any failure (`max_fail_percentage: 0`).
  A failed dist-upgrade is recovered at the console; guests are already
  evacuated, so the estate stays up while oracle is repaired.

## Stopgap if the window slips

The RRD-error flood can be dropped at the OTel collector (filter
`RRD update error` from oracle) so Loki isn't drowned, leaving oracle on 8.3
until the window. Treats the noise, not the unsupported mixed-version cluster.

## Open decisions for the operator

1. Evacuate-then-upgrade (recommended) vs full-outage console window?
2. Is oracle console/IPMI access available? (gates the remote path.)
3. Acceptable downtime window for the identity CTs (keycloak/openbao/step-ca)?
4. After upgrade: rebalance guests back to oracle, or re-home permanently and
   update `config/vm.yml`?
