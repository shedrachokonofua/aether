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
- **`kata-reclaim`** is the same Kata and hypervisor with its settings changed (`tofu/home/kata/configuration-reclaim.toml`). `reclaim_guest_freed_memory = true` returns freed guest pages to the node. The others are the virtio-fs cache mode, compared below, and two found by the canary after it.
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
- `metadata` holds nothing and costs 15-30% on small files. It is what the handler uses. Kata 3.32.0's own comment lists only `never`, `auto` and `always`; virtiofsd accepts `metadata` and the pod ran.
- Re-reading one 300 MiB file five times took 1.2 s in every mode.

**Canary with real toolchains (14:25-15:05).** Python (shared `mmap`, SQLite in WAL mode), git (5,000 files, commit, gc, fsck), cargo, Bun (SQLite, files) and Postgres (initdb, pgbench), each on the pod's disk volume and on its root filesystem. It found two faults in the configuration above, both fixed before any real pod used the handler:

- **Shared `mmap` failed.** With the data cache off, a shared writable `mmap` of a file returned `ENODEV`: Python's `mmap` raised and SQLite reported "disk I/O error" under Python and Bun. virtiofsd's `--allow-mmap` fixes it.
- **Real work left nothing to return.** After a 40-crate cargo build the guest had 290 Mi in use and 7.7 GiB free, but the VM still held 914 Mi, the same as stock Kata (906 Mi). The guest reports only free blocks of 2 MiB, and after a build its free memory is in smaller pieces (17,000 single free pages). The guest kernel parameter `page_reporting.page_reporting_order=0` reports every free page: the VM fell from 844 Mi to 510 Mi in 30 s and 439 Mi in 90 s. Order 4 did not help (812 Mi).

On the final configuration (reclaim, `metadata`, `--allow-mmap`, reporting order 0) everything passed, at about stock speed:

| | `kata` (stock) | `kata-reclaim` (final) |
|---|---|---|
| cargo build, 40 crates, cold / again | 30 s / 22 s | 29 s / 25 s |
| VM memory 90 s after the build | 906 Mi | 439 Mi |
| git, 5,000 files (volume / root) | 37 s / 42 s | 41 s / 25 s |
| Python `mmap` + SQLite WAL, 50,000 rows | 2.5 s | 3.9 s |
| Bun SQLite + 20 MB file | 2.0 s / 1.1 s | 1.3 s / 1.2 s |
| Postgres pgbench, scale 5 | 47 tps | 107 tps |

## What changed

- **Eviction floor on trinity** (`0ec55cc`): `kubelet_eviction_memory_available: "5Gi"` in `config/vm.yml` becomes kubelet `evictionHard`. Applied 13:20 with a kubelet restart, no reboot; allocatable memory went from 30.7 to 25.8 GiB. The kubelet now evicts the pod furthest over its request while the node can still act. It would have fired at about 12:00 on 11-18. A sandbox lost this way fails its job; the node, the API server and etcd stay up.
- **`kata-reclaim` handler and RuntimeClass** (`bc7c0d2` to `0d509cd`): on smith for the trials, then on niobe and trinity (15:00, a CRI restart each, no pod restarts). Talos writes `/var/lib/kata-reclaim/configuration.toml` only at boot, so on each running node it was copied into place by a pod; the content is the repo file, and a reboot rewrites the same file.
- **Daimyo task pods and sandboxes run on `kata-reclaim`** (`67f88bc`, applied 15:20): `launcher.runtimeClass`, which sandboxes inherit. Checked with real turns: `qa/e2e-omp` (bash, `eval`) and `orion` (a Pharos MCP call, bash with a file write, a scout subagent) both succeeded on it. Pods already running stay on `kata` until they end: sessions idle out after 4 h and sandboxes live up to 24 h, so the eviction floor still matters until then.
- **The Daimyo chart renders `config.sandbox.runtimeClass`** (so/daimyo `764cd3b`) and **a chart edit is now a release diff** (`c271c14`, `chartFilesSha1`). The first attempt to switch sandboxes alone was applied as a no-op: the chart did not render the section, and a local-path chart at a fixed version plans as "No changes" when only its files change.

- **Eviction floor on smith**, 4 Gi (applied 15:30): with eleven pods still on the stock `kata` handler, the kubelet's available memory there fell from 23 to 8 GiB between 13:40 and 15:20.

Not changed: sandbox requests, the `kata` handler (the `daimyo-molecule` runner still uses it), and niobe's eviction floor (92% of its memory is requested, so a lower allocatable could reject pods when its kubelet restarts).

## Still open

1. **Watch it under real load.** No Cicada sandbox had started on `kata-reclaim` when this was written. The check is whether sandboxes still end at their peak: `k8s.pod.memory.working_set` for `cicada-tasks/sandbox-%`, last value against maximum (51 of 51 were at 100% before).
2. **Charge the whole VM to its pod**: `sandbox_cgroup_only = true` plus a RuntimeClass `overhead.podFixed`, so the 10% outside the pod cgroup is limited and scheduled for.
3. **Sandbox requests** (2-3 Gi against a 5 Gi 90th percentile under `kata`) should be re-measured once sandboxes have run on `kata-reclaim`; they may now be right.
4. **Give the OOM controller a better victim than Cilium.** The Cilium agent has a request and no limit, so it has no `memory.max` and ranks first. Open since August.
5. **The Kata config is a copy.** It is the 3.32.0 extension's file with four changes; a Talos or extension upgrade needs it re-copied. Talos 1.14 can write it as an `EtcFileConfig` document, which the talos provider 0.11.0 does not know.
6. **gVisor for task pods** returned memory fully and needs no nested KVM (the reason neo left the Kata pool), but it is a userspace kernel, not a VM. Not needed if this holds.
7. **`cicada-tasks` is at its CPU-limit quota** (31.5 of 32): Daimyo logged session pods refused for it during the rollout. Unrelated to memory.

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
