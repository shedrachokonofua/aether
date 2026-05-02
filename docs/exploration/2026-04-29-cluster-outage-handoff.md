# Cluster outage handoff — 2026-04-29

## TL;DR

Today's commit **`9857c95 "Move Talos CI storage local"`** (applied via `tofu apply` around **18:30 EDT**) restructured the disk layout on `talos-trinity` and `talos-niobe` and rebooted them. They came back up but never finished booting Kubernetes services because Talos's machine config tells them to mount `/dev/vdc`, while the guest now exposes the new CI disk as `/dev/vdb`. Two of three control planes are stuck in this state, etcd has no quorum, the API server isn't reachable, and Cilium has no working control plane to announce the VIP — so the "whole cluster network went down".

`talos-neo` (the third CP) was rebooted by the user during recovery; HA had also relocated its Proxmox VM config to `trinity` while neo was down, where it stayed in `error` state. That's already been fixed (config moved back to neo, VM started, HA disabled on all four Talos VMs). **Neo is up, but the cluster is still broken** until trinity and niobe are unstuck.

## Resolution update — 2026-04-29 19:12 EDT

Cluster service is restored.

- Patched `talos-trinity` and `talos-niobe` live Talos machine configs so the CI disk mount points at `/dev/vdb` instead of `/dev/vdc`.
- Both nodes rebooted cleanly; `/var/mnt/ci` is mounted from `/dev/vdb1`, and their Talos services including `etcd`, `cri`, and `kubelet` are healthy.
- `talos-neo` was reachable and had the CI disk correctly configured as `/dev/vdd` and GPU storage as `/dev/vdc`, but its local `/var/lib/etcd` had a stale member ID. Took an etcd snapshot from `talos-trinity`, cordoned neo, wiped only the Talos `EPHEMERAL` system partition, rebooted it, and uncordoned it after it returned Ready.
- Current verified state: all Kubernetes nodes are Ready; all three etcd services are `Running/OK`; etcd members are `talos-trinity`, `talos-niobe`, and `talos-neo`; kube-apiserver/controller-manager/scheduler pods are running on all three control planes.
- Permanent IaC fix is in `tofu/home/talos_cluster.tf`: CI disk device selection now accounts for whether lower-numbered virtio disks are attached.
- Follow-up cleanup removes neo's legacy 32G etcd disk from IaC. After removal, neo's GPU storage disk compacts to `/dev/vdb` and CI disk compacts to `/dev/vdc`; etcd remains on EPHEMERAL.

## Timeline (UTC inside Talos / EDT on hosts; UTC ≈ EDT+4h)

| Time (EDT) | Event |
|---|---|
| ~10:17 | Commit `9857c95` authored. |
| ~18:30:01 | `niobe` (192.168.2.201) Proxmox host **rebooted** (`software wrote 0x6 to reset control register 0xCF9` in dmesg). |
| ~18:30:03 | `trinity` (192.168.2.202) Proxmox host **rebooted** (within 2 seconds of niobe — almost certainly the same `tofu apply` cycling them via VM reconfigure, or a VM-restart that pulled in the host). |
| ~18:33 (22:33 UTC) | `talos-trinity` and `talos-niobe` VMs come back. EPHEMERAL mounts RW. `mountUserDisks` task starts looking for `/dev/vdc`. KubeletServiceController starts failing immediately with `error writing kubelet PKI: open /etc/kubernetes/bootstrap-kubeconfig: read-only file system`. Stuck in this loop ever since. |
| ~18:35 | User notices: "whole cluster network went down, neo became unreachable". User reboots neo. |
| ~18:40 | Proxmox HA had migrated `vm:1031 (talos-neo)` config to trinity during the outage; it ended up in `error` state because the VM has GPU passthrough + local-LVM disks that only exist on neo. |
| ~18:50 | User asks Claude for help. |
| ~19:05 | Claude moved 1031 config back to neo, started VM. Removed all 4 Talos VMs (1030/1031/1032/1034) from Proxmox HA per user request. |
| ~19:15 | Diagnosed root cause (this doc). |

## Current state

### Proxmox VMs

```
neo:     1031 talos-neo      running  (just brought back; etcd crashlooping, single-node, no quorum)
niobe:   1032 talos-niobe    running  (BROKEN: kubelet/etcd never started)
trinity: 1030 talos-trinity  running  (BROKEN: kubelet/etcd never started)
smith:   1034 talos-smith    running  (worker, fine)
```

### Proxmox HA

All four Talos VMs (`vm:1030`, `vm:1031`, `vm:1032`, `vm:1034`) **removed from HA** today. Confirmed via `ssh root@oracle ha-manager status`. Remaining HA-managed services: `vm:1006` (gitlab), `vm:1015` (cockpit), `vm:1016` (messaging-stack), `vm:1020` (media-stack). HA group is `ceph-workloads`.

This was an explicit user decision: k8s nodes self-heal at the k8s layer, so HA-migrating a Talos VM (especially one with local-LVM disks or GPU passthrough) is at best redundant, at worst catastrophic. **Keep HA off for Talos VMs going forward.** This needs to be reflected in IaC — see "Followups".

### kubectl / talosctl

- `kubectl` is unusable: kubeconfig points at `https://10.0.3.16:6443`, which is `talos-trinity`. trinity has no kube-apiserver static pod running (no kubelet → no static pods).
- `talosctl` works directly against each node IP. Talos endpoints are at `apid` (port 50000).
- VIP `10.0.3.20` is dead (Cilium L2 announcer needs the API server up to elect a holder).
- The kubeconfig also tries the VIP — same result.
- **Note re: CLAUDE.md**: it claims VIP is `10.0.3.19`. Current actual VIP from the running config is `10.0.3.20`. Either the doc is stale or VIP changed. Don't trust the doc — check live before relying on it.

### kubectl context drift on this user's machine

Before this debugging started, `kubectl config current-context` was `seven30` and `KUBECONFIG=/Users/shdrch/.seven30/k8s/config` (set by another project's direnv). To work on aether you must `unset KUBECONFIG` so it falls back to `~/.kube/config`. `task k8s:auth` rewrites `~/.kube/config` to point at aether but does **not** unset `KUBECONFIG`, so if you forget to unset it, you'll silently keep talking to the wrong cluster.

## Root cause (detailed)

### What changed in commit `9857c95`

The commit "Move Talos CI storage local" did three things to the disk layout in `tofu/home/talos_cluster.tf`:

1. Added an optional **CI disk** (`ci_disk_gb`) at `virtio3`, mounted at `/var/mnt/ci` for GitLab Runner scratch/cache.
2. Kept the **legacy etcd disk** at `virtio1` only on nodes that already had it (i.e., `talos_neo`, which still has `legacy_etcd_disk_gb: 32`). Removed it from trinity and niobe.
3. Updated the Talos machine config patch so nodes with `ci_disk_gb` partition `/dev/vdc` (or `/dev/vdd` on neo because of the GPU storage disk).

`config/vm.yml` after the change:

```yaml
talos_trinity:  disk_gb: 128, ci_disk_gb: 128                                          # 2 disks total
talos_niobe:    disk_gb: 128, ci_disk_gb: 128                                          # 2 disks total
talos_neo:      disk_gb: 256, legacy_etcd_disk_gb: 32, ci_disk_gb: 128, gpu_storage_disk_gb: 500  # 4 disks total
```

### The bug

`tofu/home/talos_cluster.tf:357`:

```hcl
device = try(each.value.gpu_storage_disk_gb, null) != null ? "/dev/vdd" : "/dev/vdc"
```

The branch that picks `/dev/vdc` assumes the guest has a virtio1 disk in front of the virtio3 ci_disk so that block-device naming compacts to `vdc`. That assumption holds on a 3-disk node (virtio0 root + virtio1 legacy_etcd + virtio3 ci_disk → vda/vdb/vdc) but **not** on the new 2-disk layout (virtio0 root + virtio3 ci_disk → vda/vdb).

The comment block at `talos_cluster.tf:178-183` even spells out the expectation:

> Uses virtio3 deliberately so it cannot collide with existing virtio1 etcd disks or neo's virtio2 GPU storage during rolling migration. Talos device names are compacted by the guest, so this appears as **/dev/vdc on non-GPU nodes** and /dev/vdd on neo.

That's wrong for the post-9857c95 layout: with no virtio1 disk, virtio3 enumerates as `/dev/vdb`, not `/dev/vdc`. Linux's `virtio_blk` names devices in the order the bus enumerates them, not by virtio bus number, so gaps don't insert phantom letters.

Verified live (`talosctl get discoveredvolumes -n 10.0.3.16`):

```
vda   137 GB  gpt
  vda1 EFI   vda2 BIOS   vda3 BOOT   vda4 META   vda5 STATE   vda6 EPHEMERAL
vdb   137 GB  gpt
  vdb1  xfs                                       # this is the ci_disk
# no vdc
```

### Why this cascades to "read-only filesystem"

Talos's boot sequence (visible in the dmesg of trinity + niobe):

1. `mountEphemeralPartition` succeeds (EPHEMERAL → /var, RW).
2. `mountUserDisks` starts. It looks up `/dev/vdc` per the machine config, fails: `error processing user disk /dev/vdc: error resolving device path: lstat /dev/vdc: no such file or directory`. Retries forever.
3. Subsequent boot tasks that depend on `mountUserDisks` (including the overlay setup for `/etc/kubernetes`, `/etc/cni`, `/usr/libexec/kubernetes`, `/opt`) never complete the *upper layer*. The overlays exist in `volumestatus` as "ready" but their writeable upper layer was never wired up — so writes hit the read-only squashfs rootfs and surface as `EROFS`.
4. KubeletServiceController tries to write `/etc/kubernetes/bootstrap-kubeconfig` → `read-only file system`. Restarts every 30s–90s with no progress. Same on NodeApplyController, etc.

So the "read-only filesystem" symptom is indirect: it's not that the disks went RO at the kernel level (no XFS errors in dmesg, EPHEMERAL was mounted RW) — it's that the system never got past the `mountUserDisks` blocker to wire up the writable overlay over `/etc/kubernetes`.

### Why this took down everything

- Trinity and niobe both stuck → 2 of 3 CPs out → **etcd loses quorum**.
- Neo's etcd alone can't form a cluster (it crashloops with `listener failed: server is stopping` because peers are unreachable).
- No etcd → no kube-apiserver — across **all** CPs.
- Cilium can't elect a leader for L2 announcements → VIP `10.0.3.20` not announced.
- All in-cluster traffic (CoreDNS, ingress, Gateway API, Cilium-mesh) breaks.
- From outside the cluster: anything pointed at the VIP or any CP IP fails. `home.shdr.ch` apps go dark.

The fact that `niobe` and `trinity` rebooted within 2 seconds of each other at 18:30 was the smoking gun. `tofu apply` of `9857c95` triggered VM reconfigure on both at once (HA group change + disk attachment). Both nodes lost quorum simultaneously, and both came back broken in the same way.

## What's already been done

1. **HA cleanup**: `ha-manager remove vm:1030 vm:1031 vm:1032 vm:1034` from oracle.
2. **talos-neo VM relocated back to neo**: HA had moved 1031's config (`/etc/pve/nodes/.../qemu-server/1031.conf`) to trinity while neo was down. Trinity didn't have neo's local-LVM disks (vm-1031-disk-0..7) or the RTX 6000 PCI passthrough, so it failed to start. Manually moved the conf back from `trinity/qemu-server/1031.conf` to `neo/qemu-server/1031.conf`, then `qm start 1031`. Disks were intact on neo's `pve` VG the whole time.
3. **Confirmed root cause** (this doc).

## What still needs to happen

### Step 1 — Get trinity + niobe unstuck (URGENT, cluster is down)

Two viable paths:

**Path A (recommended): patch the Talos machineconfig in place to point at `/dev/vdb`.**

```bash
# Per node — write a small patch and apply via talosctl. Use --insecure if needed
# to bypass the apid auth that depends on a working CP.

cat > /tmp/ci-disk-fix.yaml <<'EOF'
machine:
  disks:
    - device: /dev/vdb
      partitions:
        - mountpoint: /var/mnt/ci
EOF

talosctl --talosconfig ~/.talos/config -n 10.0.3.16 -e 10.0.3.16 \
  patch machineconfig --patch @/tmp/ci-disk-fix.yaml --mode reboot

# Repeat for 10.0.3.18 (niobe).
```

Note: patches are merged into existing config, but the existing `disks:` block (with `/dev/vdc`) needs to be **replaced**, not merged. Talos's strategic merge on this list isn't reliable — verify the resulting config with `talosctl get machineconfig` after apply, and if `/dev/vdc` is still present, do a full apply-config with the corrected document instead. Worst case, write the full machineconfig to a file and `apply-config --mode reboot --file …`.

**Path B: add a dummy virtio1 disk to push the ci_disk's enumeration from `vdb` to `vdc`.**

Less invasive to Talos config but more invasive to Proxmox: requires `qm set 1030 --virtio1 local-lvm:1` (and same on niobe). Not recommended — it's a workaround, not a fix, and creates an unused phantom disk.

After Path A, etcd should rejoin once trinity + niobe + neo can all see each other. Watch with:

```bash
talosctl --talosconfig ~/.talos/config -n 10.0.3.16,10.0.3.17,10.0.3.18 service etcd
talosctl --talosconfig ~/.talos/config -n 10.0.3.17 -e 10.0.3.17 etcd members
```

Once all three etcd peers are healthy, kube-apiserver static pods will start, the VIP will be announced again, and `kubectl get nodes` will start working.

### Step 2 — Fix the IaC permanently

In `tofu/home/talos_cluster.tf` (~line 354), make the device selector aware of the actual disk count, not the GPU flag alone. Something like:

```hcl
# Determine the guest device for the ci_disk. Linux compacts virtio names by
# enumeration order, not bus number, so a virtio3 disk's letter depends on how
# many other virtioN disks are present.
locals {
  # for_each will re-evaluate per-node:
  ci_disk_device = (
    try(each.value.gpu_storage_disk_gb, null) != null ? "/dev/vdd" :   # vda root + vdb legacy_etcd + vdc gpu_storage + vdd ci
    try(each.value.legacy_etcd_disk_gb, null) != null ? "/dev/vdc" :    # vda root + vdb legacy_etcd + vdc ci
    "/dev/vdb"                                                          # vda root + vdb ci
  )
}
```

Also fix the comment block at `talos_cluster.tf:178-183` to stop claiming the disk "appears as /dev/vdc on non-GPU nodes" — that's only true on nodes that also have `legacy_etcd_disk_gb`.

After fixing, `tofu apply` will reconcile the machine config via the talos provider — but **only after the cluster API is reachable again** (the talos provider talks to apid, which is independent of the kube-apiserver, so this should work as soon as Step 1 completes).

### Step 3 — Bake "no HA on Talos VMs" into IaC

The HA group membership is currently set by hand (`ha-manager add vm:NNNN --group ceph-workloads ...`). Whatever creates that should be updated to **exclude** Talos VMs (`vm:1030`, `vm:1031`, `vm:1032`, `vm:1034`). Search the repo for `ha-manager`, `ha_resource`, `ceph-workloads` to find the source of truth — likely an Ansible playbook under `ansible/playbooks/` since the Proxmox HA configuration isn't in tofu.

Why HA must stay off for these:
- `talos-neo` has GPU passthrough + local-LVM disks (vm-1031-disk-0..7) tied to neo's hardware. Migrating it elsewhere always fails.
- `talos-trinity` and `talos-niobe` have local-LVM disks too. Even if they could move, the right answer to a node failure is for k8s to evacuate workloads, not for Proxmox to revive a corpse on another host.
- `talos-smith` already has `max_relocate 0` for the same reason.

### Step 4 — Investigate why both Proxmox hosts rebooted simultaneously

`/proc/sys/kernel/version` and `dmesg`'s "Previous system reset reason [0x00080800]: software wrote 0x6 to reset control register 0xCF9" both confirm this was a clean software-initiated reboot, not a power blip or kernel panic. The most likely cause is `tofu apply` of `9857c95` reconfiguring the VMs and inadvertently triggering host reboots — but worth confirming, because that's not normal behavior. Check:

- `journalctl -u qemu-server@1030 -u qemu-server@1032 --since "today"` on each host.
- Proxmox cluster log: `journalctl -u corosync -u pve-cluster --since "today" | grep -iE 'reboot|shutdown|fence'`.
- Whether the proxmox terraform provider's VM update triggered a `qm reboot` of the host (it shouldn't — that'd be a bug in the provider). More likely the provider rebooted the *guest* VM and the user observed VM downtime, not host downtime; my "host rebooted" reading is from the talos VM's `dmesg` showing kernel boot timestamps. Re-verify on the bare-metal hosts.

### Step 5 — Update CLAUDE.md / docs

CLAUDE.md says VIP is `10.0.3.19`. Currently it's `10.0.3.20`. After the cluster is back up, confirm the live value (`kubectl get ciliuml2announcementpolicy -A` or similar) and fix the doc.

## Useful commands for the next person

```bash
# Get into the dev shell + auth
nix develop
unset KUBECONFIG && task k8s:auth

# Talos: services on each CP
talosctl --talosconfig ~/.talos/config -n 10.0.3.16 -e 10.0.3.16 services
talosctl --talosconfig ~/.talos/config -n 10.0.3.17 -e 10.0.3.17 services
talosctl --talosconfig ~/.talos/config -n 10.0.3.18 -e 10.0.3.18 services

# Talos: discovered volumes (proves /dev/vdc is missing on trinity/niobe)
talosctl --talosconfig ~/.talos/config -n 10.0.3.16 -e 10.0.3.16 get discoveredvolumes

# Talos: read the controller failures live
talosctl --talosconfig ~/.talos/config -n 10.0.3.16 -e 10.0.3.16 dmesg | tail -40

# Proxmox: VMs per host (homelab IPs are 192.168.2.201..205 = niobe/trinity/oracle/smith/neo)
for ip in 201 202 203 204 205; do echo "=== 192.168.2.$ip ==="; ssh root@192.168.2.$ip 'qm list'; done

# Proxmox: HA state (any node works; oracle is convenient since it's not k8s)
ssh root@192.168.2.203 'ha-manager status; ha-manager config'

# Where Proxmox cluster keeps per-node VM configs
ls /etc/pve/nodes/<node>/qemu-server/
```

## Inventory cheat sheet

```
Proxmox hosts (bare metal, 192.168.2.0/24)
  niobe    .201   talos-niobe (CP)
  trinity  .202   talos-trinity (CP), gitlab, media-stack
  oracle   .203   router, home-gateway, IDS, keycloak/bao/etc.
  smith    .204   talos-smith (worker), nfs, backup, blockchain, game-server
  neo      .205   talos-neo (CP w/ GPU, local-NVMe)

Talos nodes (10.0.3.0/24, VLAN 3)
  10.0.3.16  talos-trinity   CP
  10.0.3.17  talos-neo       CP   (RTX 6000 + local NVMe + ci_disk + legacy_etcd)
  10.0.3.18  talos-niobe     CP
  10.0.3.20  VIP             (down right now; CLAUDE.md still says .19, verify after recovery)
  10.0.3.22  talos-smith     worker (amd64)
  10.0.3.23  talos-tank      worker (arm64, Pi)
  10.0.3.24  talos-dozer     worker (arm64, Pi)
  10.0.3.25  talos-mouse     worker (arm64, Pi)
  10.0.3.26  talos-sparks    worker (arm64, Pi)
```
