# Kata VM memory filled talos-trinity (2026-11-18)

**Node:** `talos-trinity` (10.0.3.16, 32 GiB, control plane, etcd member) · **Seen as:** Orion and `home.shdr.ch` down, `kube-apiserver-talos-trinity` in CrashLoopBackOff, node `NotReady` 13:03-13:10 UTC · **Reboot:** none, it recovered when the kubelet came back.

## Summary

Kata pods filled the node's memory with shared memory that nothing could reclaim. The node thrashed, its API server and etcd stalled, the kubelet stopped reporting, and the pods on it (Orion, Pharos, Open WebUI among them) were evicted and then stuck waiting for their volumes.

The cause is how a Kata VM uses memory, and it is not specific to this day: trinity reached zero available memory on 9, 10, 11, 15, 17 and 18 November.

1. **A Kata VM never returns memory.** Guest RAM is shared memory on the node (virtio-fs needs it shared). With the default settings the guest keeps file data in its page cache and the hypervisor is never told about freed pages, so a pod's use only climbs, toward `default_memory` (2 GiB) plus its limit.
2. **The node cannot take it back.** Shared memory is not page cache: without swap it cannot be reclaimed. A runc pod's file cache can.
3. **The scheduler counts requests.** Cicada sandboxes request 2-3 Gi and are limited to 6-8 Gi; their measured use sits between the two and never comes down.
4. **Nothing stepped in.** The kubelet evicts at 100 Mi available and still saw 3.3-3.6 GiB. Talos's OOM controller spares every pod that has a memory limit, which is every Kata pod, and killed Cilium and the API server.

## Timeline (UTC)

| When | What |
|---|---|
| 2026-10-29 | `f513ca5` lowers sandbox memory requests to 2-3 Gi, from a `kubectl top` reading of ~0.5 Gi taken before the VM had filled |
| 2026-11-06 | `cb9f9e6` takes `talos-neo` out of the Kata pool. Kata pods now fit only `talos-smith`, `talos-niobe` and `talos-trinity` |
| 11-09 onward | Sandboxes run on trinity for the first time; its shared memory goes from ≤7.5 GiB to 24 GiB and available memory hits 0 that day and on five later days |
| 11-17 11:06 | trinity's last boot. Shared memory is back at 26 GiB within the hour |
| 11-18 00:25 | Talos OOM controller starts firing on trinity; victim is the Cilium agent's cgroup |
| 12:37 | `kube-apiserver-talos-trinity` crash-loops on etcd timeouts (the OOM controller is killing it too) |
| 12:40, 13:00 | Node stalls: I/O and memory pressure saturate for minutes at a time, load average 160 |
| 13:03:06 | Kubelet stops posting status; node `NotReady`; pods get the unreachable taint |
| 13:08 | Pods evicted. Replacements on other nodes wait for RBD volumes still attached to the stalled node |
| 13:10:15 | Kubelet answers again, removes the evicted pods (all Kata VMs on the node end), 24 GiB is freed, node `Ready` |
| 13:14 | Orion, Pharos and `home.shdr.ch` answer |
| 13:20 | Eviction floor of 5 Gi applied to trinity (below) |

## Evidence

**State at 13:10, before recovery** (`talosctl -n 10.0.3.16`): `MemTotal` 32 GiB, `Shmem` 24.9 GiB, `MemAvailable` 1.0 GiB, no swap; load 161; PSI `io some avg10=98`, `memory full avg10=10.9`; largest processes `cloud-hypervisor` and `virtiofsd` at 2.7-7.2 GiB RSS each; etcd and kubelet failing health checks. Uptime 26 h: no reboot.

**Who held it** (ClickHouse `k8s.pod.memory.working_set`, trinity, 13:00): 4 Cicada sandboxes 12.2 GiB, 10 task pods 4.9 GiB, CI runner pods 1-7 GiB in bursts, everything else 2.9 GiB. Node shared memory was 24 GiB, so several GiB of VM memory sat outside any pod's accounting (next point).

**Not all of a VM is in its pod's cgroup.** On smith a VM mapped 2.25 GiB of guest memory while its pod cgroup was charged 2.02 GiB. `sandbox_cgroup_only = false` puts virtiofsd and the non-vCPU hypervisor threads in `/kata_overhead`, which has no limit, and shared pages are charged to whoever touches them first. That cgroup held 3.5 GiB of shared memory on smith for ten VMs, and 744 leftover per-sandbox child cgroups.

**It never comes back** (ClickHouse, 14 days, sandboxes that lived over 20 minutes):

| Sandbox class | Request | Limit | Pods | Median peak | 90th percentile | Max |
|---|---|---|---|---|---|---|
| turmeric, buyerfact | 2 Gi | 6 Gi | 164 | 2.6 GiB | 5.07 GiB | 5.6 GiB |
| molecule, cicada | 3 Gi | 8 Gi | 73 | 2.15 GiB | 2.43 GiB | 4.55 GiB |

Over three days, 0 of 51 sandboxes ended below 80% of their peak. One held 5.53 GiB for five idle hours. Task pods (768 Mi-1 Gi requested, 2 Gi limit) peak at 0.56 GiB on average and 1.21 GiB at most: they are not the problem.

**Why trinity.** The scheduler places by requests. On 11-18 smith had 85% of its memory requested and niobe 92%; trinity had 25%, so new Kata pods went there.

**Why no safeguard fired.**
- Kubelet: `evictionHard memory.available` was the 100 Mi default. During the stall the kubelet's own figure was 3.3-3.6 GiB while `MemAvailable` was 0-1.9 GiB.
- Talos OOM controller: 196 kills on trinity that day, 178 of the Cilium agent pod (34 restarts) and 18 of a static control-plane pod. It skips pod cgroups that have `memory.max`, which every Kata pod has. Same mechanism as [`talos-oom-sweeps-2026-08.md`](talos-oom-sweeps-2026-08.md).
- Kernel OOM killer: no pod reached its own limit, and the kernel kept evicting file pages (binaries, so the node thrashed) and never declared the node out of memory.

## Trials on talos-smith (13:26-14:15)

**Does memory come back?** The same steps in a pod limited to 4 Gi: write and read back a 1500 MiB file, hold 1000 MiB in tmpfs, free both, wait. Node memory is the pod cgroup's `memory.current`.

| Runtime | After the file | After the tmpfs data | 60-90 s after freeing everything |
|---|---|---|---|
| `kata` (stock) | 1586 Mi | 2588 Mi | **2588 Mi** |
| `kata-reclaim` (cache `never`) | 75 Mi | 721 Mi | **85 Mi** |
| gVisor (`runsc`, systrap) | 1535 Mi, reclaimable file cache | 2540 Mi | **34 Mi** |

- **Stock Kata** kept all 2.5 GiB although the guest reported 5.9 GiB free. The guest sees 6 GiB of RAM for a 4 Gi limit.
- **`kata-reclaim`** is the same Kata and hypervisor with two settings changed (`tofu/home/kata/configuration-reclaim.toml`). `reclaim_guest_freed_memory = true` returns freed guest pages to the node. The second is the virtio-fs cache mode, compared below.
- **gVisor** keeps file data in the node's page cache, which the node can reclaim, and returned everything.

**Which virtio-fs cache mode?** All with reclaim on, except the stock row. Node memory here is the VM process's resident shared memory, which also counts what is charged outside the pod cgroup (a VM starts at about 210 Mi).

| `virtio_fs_cache` | Node memory with a 1500 MiB file kept | After deleting it | 1500 MiB write | 20,000 small files written, read, removed |
|---|---|---|---|---|
| `auto`, no reclaim (stock) | 1716 Mi | 1718 Mi | 31-45 MB/s | 35 s |
| `auto` | 1718 Mi | 229 Mi | 45 MB/s | 40 s |
| `metadata` | **217 Mi** | 217 Mi | 302 MB/s | 41-46 s |
| `never` | 213 Mi | 214 Mi | 306 MB/s | 74-78 s |

- `auto` with reclaim gives memory back only when files are deleted; a build tree that stays keeps holding it.
- `never` holds nothing but doubles the time of small-file work, which is what builds do.
- `metadata` holds nothing and costs 15-30% on small files. It is what the handler now uses. Kata 3.32.0's own comment lists only `never`, `auto` and `always`; virtiofsd accepts `metadata` and the pod ran.
- Re-reading one 300 MiB file five times took 1.2 s in every mode.

## What changed

- **Eviction floor on trinity** (`0ec55cc`): `kubelet_eviction_memory_available: "5Gi"` in `config/vm.yml` becomes kubelet `evictionHard`. Applied 13:20 with a kubelet restart, no reboot; allocatable memory went from 30.7 to 25.8 GiB. The kubelet now evicts the pod furthest over its request while the node can still act. It would have fired at about 12:00 on 11-18. A sandbox lost this way fails its job; the node, the API server and etcd stay up.
- **`kata-reclaim` handler and RuntimeClass on smith** (`bc7c0d2`, `3401ee4`, cache mode set to `metadata` afterwards): for the trials above. Nothing uses it unless a pod names it. Talos writes `/var/lib/kata-reclaim/configuration.toml` only at boot, so it was copied into place by a pod; the content is the repo file.

Not changed: sandbox requests, the `kata` handler, the other Kata nodes.

## Options from here

1. **Move Kata pods to `kata-reclaim`.** Needs the handler on niobe and trinity (a CRI restart each, and the config file, which appears at the next boot or can be copied as on smith), then Daimyo's `runtimeClass`. Canary first on `qa/e2e-omp` and one Cicada sandbox build: the trials used synthetic file work, not a real cargo or bun build, and did not exercise shared writable `mmap` on virtio-fs files (SQLite, some build tools), which a changed cache mode can affect.
2. **Charge the whole VM to its pod**: `sandbox_cgroup_only = true` plus a RuntimeClass `overhead.podFixed`, so the 10% outside the pod cgroup is limited and scheduled for.
3. **Raise sandbox requests to what they use** (5 Gi for the 6 Gi classes is the 90th percentile). `cicada-tasks` allows 40 Gi of memory requests, which seven such sandboxes and ten tasks exceed, so the quota moves with it. Less urgent if option 1 holds.
4. **Give the OOM controller a better victim than Cilium.** The Cilium agent has a request and no limit, so it has no `memory.max` and ranks first. Open since August.
5. **gVisor for task pods.** It returned memory fully and needs no nested KVM (the reason neo left the Kata pool), but it is a userspace kernel, not a VM: weaker isolation, no `io_uring`, and Postgres, ClickHouse and Chromium under it are unproven here. A candidate for the agent task pods, not yet for CI sandboxes.
6. **Swap or zswap on the Kata nodes** would let idle VM memory be paged out. Untested, and it needs a swap disk per VM.

## Reproduce

```bash
# shared memory and the stall
talosctl -n 10.0.3.16 read /proc/meminfo | grep -E 'MemAvailable|Shmem:'
talosctl -n 10.0.3.16 read /proc/pressure/io
talosctl -n 10.0.3.16 dmesg | grep -c 'OOM controller triggered'
# what the kubelet thinks is available, and its floor
kubectl get --raw /api/v1/nodes/talos-trinity/proxy/stats/summary | jq '.node.memory.availableBytes'
kubectl get --raw /api/v1/nodes/talos-trinity/proxy/configz | jq '.kubeletconfig.evictionHard'
# a Kata pod's charge on its node
talosctl -n <node> read /sys/fs/cgroup/kubepods/burstable/pod<uid>/memory.stat | grep -E '^(shmem|file|anon) '
```

ClickHouse: `node_memory_Shmem_bytes` and `node_memory_MemAvailable_bytes` by `ResourceAttributes['k8s.node.name']`; `k8s.pod.memory.working_set` for `ServiceName LIKE '%-tasks/sandbox-%'`.
