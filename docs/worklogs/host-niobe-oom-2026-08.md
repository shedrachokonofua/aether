# Host niobe kernel slab leak → control-plane VM OOM-killed (2026-08-16)

**Host:** `niobe` (192.168.2.201, 64GB) · **Victim:** `talos-niobe` VM (qemu/1032, 24Gi, etcd member) · **Detected via:** `Host High Memory`, `Talos Node Memory Pressure (PSI)`, `Kubernetes Node Readiness Flapping`, cilium-operator CrashLoopBackOff.

## Timeline (UTC)

| time | event |
|---|---|
| Aug 15 20:50 | `Host High Memory` fires (chronic: 45Gi VMs + overhead on 58Gi usable, ~11Gi slack) |
| Aug 16 18:55 | unreclaimable kmalloc slab starts growing from 3.4Gi at ~3.5Gi/h. No PVE task, no process I/O spike, no socket/conntrack growth |
| 20:20 | host PSI 0.19s/s bleeds into the guest: talos-niobe PSI alert while guest has 8.4Gi free |
| 22:12–22:56 | apiserver/lease calls through the VIP time out in bursts; four nodes blip NotReady simultaneously at 22:18; cilium-operator loses leader election → CrashLoop |
| 22:58 | host OOM killer takes the largest anon process: kvm/talos-niobe (`anon-rss:20753252kB`, dmesg). Slab at ~17.8Gi |
| 23:41–00:15 | investigation via SSH; slab growth already stopped at ~20.1Gi |
| 00:2x | lute rig teardown (below) — **slab did NOT free** (21.2→20.9GB). Orphaned kernel memory; only a reboot reclaims it |
| 00:3x | `qm start 1032`: node Ready in 20s, etcd 3/3, cilium-operator stable |

## What was on the host

An abandoned data-recovery rig for the old `lute` VM (1011), built Aug 2 from an SSH
session whose scope shows `active (abandoned)`:

PBS snapshot (Feb 12) → `proxmox-backup-client map` (fuse) → `/dev/loop1p4` btrfs
`ro,rescue=nologreplay` (~1M inodes) → overlayfs (upper: ext4 image looped off
cephfs) → MinIO server running on the host. Recovery `mc mirror` units failed
Aug 3 and never ran again; the mount stack and MinIO stayed up 14 days.

Teardown (approved): stopped `lute-*` units, killed MinIO + the map process,
unmounted all four layers. All backing artifacts preserved (PBS snapshot
immutable, overlay upper on cephfs, scratch btrfs in `/var/tmp`). Rebuild
recipe = the mount list above.

## Root cause status

Slab consumer confirmed *adjacent* to the rig (btrfs_inode + ovl_inode ≈ 1M
objects each; kmalloc-rnd generic caches ≈ 18Gi; only host with the rig, only
host with growth) but the memory did not return on teardown, so the precise
allocation site is unproven — generic kmalloc caches carry no owner without
`slub_debug`. The 18:55Z userspace trigger was never identified: no PVE task,
scanner runs at 12:53Z/17:23Z don't match, no I/O-heavy process. **Open.**

~20Gi of orphaned kernel slab remains until the host is rebooted. Leak dormant
(0 growth). Host available ≈ 16-17Gi with all five VMs running — enough, with
no margin for another event. **Reboot host niobe at the next window.**

## The ".231 brute force" — resolved, not an attacker

`Failed password for root from 192.168.2.231` on niobe (11 since May, burst
23:10/23:39Z tonight) and oracle (4, Aug 9/12). `192.168.2.231` is the VyOS
router's own leg on the Gigahub segment, and NAT rules 101–103
(`configure_router.yml`) masquerade VLANs 2/3/4 behind it toward
192.168.2.0/24 — every internal device's failed login appears router-sourced.
Tonight's burst timestamp-matches this investigation's own expired-certificate
SSH attempts from VLAN 4; the historical entries carry the same 1-2-failures-
then-quiet human signature. The estate-scanner is structurally exonerated: it
uses `ssh -o BatchMode=yes`, which never attempts password auth and cannot
produce `Failed password` entries.

Live demonstration of the case in `exploration/east-west-nat-removal.md`:
east-west NAT destroys source identity exactly when logs matter.

## Open items — updated after remediation pass (Aug 17 00:45–01:30Z)

- ~~Reboot host niobe~~ **Done 00:48–01:15Z.** SUnreclaim 20.9GB → 184MB,
  MemAvailable 26Gi, all 5 VMs auto-started, talos-niobe Ready in 15s,
  etcd 3/3, Grafana/Prometheus 200. Wrinkle: shutdown wedged on talos-niobe —
  its qemu-guest-agent socket never answered (`guest-ping failed`, 31 retries)
  and PVE would not proceed; forced `qm stop 1032` to unblock. **Follow-up
  closed Aug 17:** qga answers on every Talos VM fleet-wide (ping + extension
  Running); the outage was a one-boot artifact of the OOM-killed qemu. The
  wedge class is now bounded regardless: all four Talos VMs carry PVE
  `startup: down=90` (tofu `startup { down_delay = 90 }`,
  `talos_cluster.tf`) — at host shutdown PVE waits 90s then force-stops,
  which Talos tolerates.
- ~~backup-stack~~ **Root-caused and mostly fixed.** Root disk 99%: Backrest
  cache (12.6G) on the 20G root because the live unit uses
  `XDG_CACHE_HOME=/var/lib/backrest/cache` while IaC declares
  `/mnt/hdd/backups-data/.backrest-cache` — live drift. Journal/apt/tmp
  cleanup freed ~2G (88% now). Restic "stale" was two things: a 12h
  `backups-vm` run (finished 00:01Z) serializing the queue, and an Aug 9 dead
  lock (PID gone) failing every `forget` — removed with `restic unlock`,
  live lock preserved. **Remaining:** after the running `data` backup (op691)
  completes, run
  `task ansible:playbook -- backup_stack/configure_offsite_backups/site.yml`
  to converge the cache onto /mnt/hdd (the play refuses to restart Backrest
  mid-operation, correctly). Alerts clear as the op queue drains.
- ~~PVE aptupdate failures~~ **Fixed fleet-wide.** Cause: enterprise repos
  (401 Unauthorized) active on all 5 hosts; oracle also had stale enterprise
  Ceph Quincy. Live: enterprise lists disabled, no-subscription ensured,
  `apt-get update` rc=0 on all 5 (niobe patched post-reboot). IaC: the repo
  hygiene in `upgrade_pve_8_to_9.yml` was gated behind `not already_upgraded`;
  now an always-run block.
- **Zeek mgmt-VLAN blindness — mapped, decision pending.** IDS taps only the
  VyOS eth1 trunk mirror (eth1→eth2→vmbr_mirror→ens19); VLAN 1 lives on eth0
  and same-L2 frames never cross the tap (`configure_router.yml:876-879` says
  so explicitly). Options: mirror eth0 too (cheap; covers router-crossing mgmt
  traffic only) or rack-switch SPAN of VLAN 1 to a dedicated IDS NIC (true
  east-west coverage; the 4vCPU/4GB IDS VM needs filtering or sizing first).
- **gigahub_observations — one artifact away.** Schema, MV, and both OTel
  routes are prepared; `gigahub_observations_enabled=false` because the pinned
  exporter v0.2.0 predates the feature. Sibling `../gigahub-exporter` already
  implements the sealed-NDJSON writer (read-only Sagemcom `/cgi/json-req`).
  Enable = cut a new artifact, bump role version+SHA, flip the flag, run
  `task configure:gigahub-exporter && task deploy:gigahub-exporter`, verify
  rows in `network.observations`.
- **Move monitoring-stack (16Gi) off host niobe** → smith (128GB, 30d floor
  4.8Gi). Ends the control-plane/observability shared failure domain and
  unblocks the planned 16→24Gi growth (July capacity worklog). Unchanged.
- **East-west NAT removal** now has an incident-grade motivation. Unchanged.
- **host oracle** (16GB, 30d floor 1.3Gi, 3.5Gi swapped) remains the next-most
  memory-fragile host. Unchanged.
