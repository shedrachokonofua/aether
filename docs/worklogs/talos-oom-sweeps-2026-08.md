# Talos OOM-controller sweeps on talos-neo — investigation and fix (2026-08-04/05)

## Summary

Between 2026-08-03 and 2026-08-05, workloads on `talos-neo` (and to a lesser
degree `talos-dozer`) were repeatedly SIGKILLed by the **Talos userspace OOM
controller** (`runtime.OOMController`, Talos ≥ 1.12) while the node had 30+ GiB
of available memory. In the 13.7 h covered by neo's kernel ring buffer
(2026-08-04 10:01 → 23:41 UTC) it executed **412 SIGKILLs across 88 sweep
episodes** (median 8.2 min apart). Collateral included jellyfin being killed
mid-transcode, kestra accumulating 122 restarts, and cascading restarts across
the GPU node.

Root cause is a three-part interaction, each part individually reasonable:

1. The controller triggers on **pressure (PSI), not capacity** — heavy page-cache
   churn fires it with plenty of free RAM.
2. Victim selection **exempts any pod cgroup with `memory.max` set and ranks the
   rest by QoS-weight × bytes** — so unlimited pods are executed for pressure
   that limited pods cause.
3. Kubelet only sets pod-level `memory.max` when **every container in the pod,
   init containers included, has a memory limit** — so a single unlimited init
   container silently strips a pod's immunity.

## Exact mechanism (Talos v1.12.1 source, verified live)

Controller: `internal/app/machined/pkg/controllers/runtime/oom.go`.
Samples PSI every **500 ms** (`defaultSampleInterval`). Defaults from
`pkg/machinery/constants/constants.go`:

```cel
# Trigger — evaluated against /sys/fs/cgroup PSI:
memory_full_avg10 > 12.0 && d_memory_full_avg10 > 0.0 && time_since_trigger > duration("500ms")

# Victim scoring — per pod cgroup; HIGHEST score is SIGKILLed, one per trigger:
memory_max.hasValue() ? 0.0 :
  {Besteffort: 1.0, Burstable: 0.5, Guaranteed: 0.0, Podruntime: 0.0, System: 0.0}[class]
    * double(memory_current.orValue(0u))
```

Consequences:

- `memory_max.hasValue() ? 0.0` — a pod-level memory limit is **total immunity**.
- While pressure keeps rising the controller re-kills every 500 ms, producing
  multi-kill sweep episodes.
- No machine-config override is present in this cluster (defaults active;
  `talosctl get oomactions` works, machine config has no `oom:` section).

Live trigger evidence (`talosctl -n 10.0.3.17 get oomactions -o yaml`, action
789, 2026-08-04T23:41:30Z):

```
memory_full_avg10: 12.95   (threshold 12.0)
memory_full_avg300: 1.31   (i.e. a short spike, not sustained exhaustion)
score: 5.472e9             (jellyfin pod: Burstable 0.5 × ~10.9 GB incl. transcode page cache)
processes: /jellyfin/jellyfin, jellyfin_exporter, ffmpeg (an active user stream)
```

Node state at the same moment: `MemAvailable: 36.6 GiB` of 62.8 GiB
(`talosctl read /proc/meminfo`). **Capacity was never the problem.**

## Metrics

Kill ledger (kernel ring buffer, 2026-08-04 10:01:26 → 23:41:53 UTC):

```
talosctl -n 10.0.3.17 dmesg | grep -E "OOM controller triggered|Sending SIGKILL"
# 412 SIGKILLs, 88 episodes (gap >120 s), inter-episode gap median 8.2 min

per pod-uid:
  e90ffac4 (llama-swap, pre-fix)   x303   73% — arsonist AND victim: its memcg
                                          thrash drove PSI; its pod cgroup was
                                          unlimited (see below) so it ranked top
  b7e09595 (kestra, BestEffort)    x68    never exceeded 2.74 GiB itself
  6d24dbd8 (replaced pod, litellm-era rollout window) x14
  aa1781cb / eec01ae7 / 13740a7a (old+new jellyfin) x11 — incl. 4 kills at
                                          23:41 during an active stream
  c65b6f96                         x3
```

Fleet scope (`dmesg | grep -c "OOM controller triggered"`): neo 412+ (13.7 h
buffer), dozer 37, smith 0, niobe 0. Note `kubectl top` shows dozer/sparks/tank
at 101–109% memory — overcommit follow-up below.

Kestra profile (Prometheus, 40 h,
`max(k8s_pod_memory_working_set_bytes{exported_job=~"kestra/.*"})`):
working set median **1.62 GiB**, p100 **2.74 GiB** (n=476). With BestEffort QoS
its score (1.0 × ~2 GiB) out-ranked every Burstable pod almost permanently →
122 restarts in 38 h despite being ~4% of node RAM.

Pod-level cgroup audit (the immunity check), before fix:

```
talosctl -n <node-ip> read /sys/fs/cgroup/kubepods/<qos>/pod<uid>/memory.max
jellyfin    -> max   (container had NO memory limit at all)
llama-swap  -> max   (container limited 40Gi, but init container unlimited
                      -> kubelet leaves pod-level memory.max unset)
kestra      -> max   (BestEffort, chart deployed with no resources)
```

## Reproduction recipe

On any Talos ≥1.12 node with default `OOMConfig` (verified on v1.12.1):

1. Deploy a BestEffort canary: a pod with no resources, e.g. `sleep infinity`
   with ~1 GiB ballast (`stress-ng --vm 1 --vm-bytes 1G --vm-hang 0`).
2. Create pressure *without exhausting the node* — either of:
   - a pod with a low memory limit running `stress-ng --vm 2 --vm-bytes 150%`
     (memcg-confined thrash; reclaim stall propagates to root PSI), or
   - sequential re-reads of a >RAM-sized file set (page-cache churn), which is
     what a 29 GiB mmap'd GGUF load or a transcode+scan does organically.
3. Watch `talosctl read /proc/pressure/memory` until `full avg10 > 12.0`.
4. Observe: `dmesg` logs `OOM controller triggered` and the **canary** (not the
   pressure source, if the source is limited → score 0.0) is SIGKILLed with
   exit 137, while `/proc/meminfo` still shows large `MemAvailable`.
5. Set a memory limit on the canary (all containers) → pod-level `memory.max`
   appears → repeat step 2 → canary survives; the controller logs triggers but
   only unlimited cgroups are eligible.

## Fix (applied 2026-08-05, this repo)

Principle: **on Talos, a pod without a full-pod memory limit is both unbounded
and first against the wall. Every long-running pod on shared nodes must have
memory limits on every container, init containers included.**

1. `tofu/home/kubernetes/kestra.tf` — chart `common.resources`
   (requests 2Gi / limits 4Gi, sized from the 40 h profile) +
   `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=50.0` (container-aware JVM would
   otherwise default to 25% = 1 GiB heap under the new limit). Note the chart
   schema wants `common.resources`; `deployments.standalone.resources` is
   silently ignored.
2. `tofu/home/kubernetes/jellyfin.tf` — 8Gi memory limit on the jellyfin
   container (exporter was already limited).
3. `tofu/home/kubernetes/llama_swap.tf` — limits on the `init-storage` init
   container (the main container's 40Gi limit alone did not set pod-level
   `memory.max`).

Verified post-apply:

```
jellyfin    on talos-neo   pod memory.max = 8689934592  (8.09Gi) Burstable
llama-swap  on talos-neo   pod memory.max = 42949672960 (40Gi)   Burstable
kestra      on talos-smith pod memory.max = 4294967296  (4Gi)    Burstable
```

All three now score 0.0 in the ranking expression. Last OOM trigger on neo was
00:03:45Z during the rollout churn itself; the standing verification is the
24 h query below.

## Verification queries

```bash
# sweeps stopped (expect no new lines after 2026-08-05T00:03:45Z):
talosctl -n 10.0.3.17 dmesg | grep "OOM controller triggered" | tail -3
# restart counters flat:
kubectl -n kestra get pods; kubectl -n jellyfin get pods; kubectl -n ai-serving get pods
# structured kill log with trigger PSI + victim process list:
talosctl -n 10.0.3.17 get oomactions -o yaml | tail -40
```

## Follow-ups (not done here)

- dozer/sparks/tank report 101–109% memory in `kubectl top` — genuine
  overcommit, separate from this mechanism.
- PVE hosts 192.168.2.202/203 show 15–18% memory full-stall PSI
  (`rate(node_pressure_memory_stalled_seconds_total{job="proxmox-hosts-node"}[5m])`)
  — chronic host-level pressure, uninvestigated.
- postgrest (vc-seven30, 237 restarts/day) — owned by the seven30 tenant repo,
  needs its limit (or its liveness probe) fixed there.
- Remaining unlimited pods on neo are daemonsets and control-plane static pods
  (cilium, csi nodeplugins, istio-cni, nvidia-device-plugin, kube-apiserver/
  controller-manager/scheduler) plus deskplane-mcp, jupyter, mingus-1 — not
  sensibly limitable one by one. The durable fix is the 1.13 upgrade below.

## Addendum (2026-08-05 00:51): limits are necessary but not sufficient on 1.12.1

The controller swept again at 00:51:34Z and killed **docling** — whose main
container had an 8Gi limit, but whose `init-models` init container did not, so
the pod-level `memory.max` was unset (same trap as llama-swap). Fixed the
ai-serving trio's init containers (docling, comfyui; speaches had no init);
verified pod-level `memory.max` = 8Gi / 32Gi post-rollout.

Alerting (deployed, `rules.yml`): `talos-node-memory-psi-high` (warning, node
full-stall >6% 3m), `talos-oom-sweep-detected` (critical, ≥2 exit-137
containers per node in 15m — caught the 00:51 sweep within minutes of
deployment), `container-memcg-oom-loop` (warning, >2 kernel OOM kills/30m).
Note the pre-existing restart-loop rule routes to `channel: digest`, which is
why 122 kestra restarts never paged.

## Why upgrade talos-neo to 1.13.x (quantified)

neo runs v1.12.1; dozer/tank run 1.13.2. Three OOM-relevant changes:

1. **Trigger rewrite.** 1.13.2 default only fires early for System/Podruntime
   cgroup stall (protecting kubelet/containerd/etcd); generic workload
   pressure needs `memory_full_avg10 > 75.0` with ≥10s between kills — vs
   1.12.1's `> 12.0` at 500ms. Every one of the 88 observed sweep episodes
   fired between 12.9 and ~15; **none would have triggered under 1.13.2
   defaults.**
2. **Zero-rank fix** (`ignore cgroups with zero rank in OOM handler`): on
   1.12.1 the victim loop starts at -inf, so when every pod scores 0.0 a
   limited pod can still be killed. On 1.12.1 limits shrink the target set;
   only 1.13 makes them a guarantee.
3. `strict QoS ordering in OOM victim selection`, `oom podruntime protection`,
   and `OOMActionLogKeep = 50` (better forensics).

Upgrade is a node reboot (drain jellyfin/llama/comfyui/docling); use the
normal Talos upgrade flow when a media-idle window exists.

## Resolution (2026-08-05)

Adversarial review (spawned reviewer agent) corrected two claims before the
final fix: the sustaining PSI source was llama-swap's memcg OOM reload churn
under an undersized 40Gi limit (VPA recommendation 56.8G), NOT an apiserver
watch-cache feedback loop; and Mingus-as-ignition was overfit. Overnight the
sweep ranking reached the CNI and control plane: cilium agent 45+ kills,
kube-apiserver-talos-neo 83+ kills.

Actions, in order:
1. OOMConfig override (75%/10s) via tofu machine config — the 1.12.1
   controller did NOT hot-reload it despite the config being active
   (contrary to a code-reading of oom.go's event loop).
2. `talosctl upgrade` talos-neo -> 1.13.2 (nvidia schematic, same ID, new
   tag). Post-check passed; NVIDIA 580.159.03 loaded; 12 GPU slots
   advertised. Zero OOM triggers since — through reboots, GPU pod storms,
   and 27B model preloads that reliably fired the old trigger.
3. llama-swap limit 40 -> 56Gi (VPA), neo excluded from the OOMConfig
   override (1.13 native defaults are better).
4. Reboot aftershock: `gpu_neo_node_selector` pinned the exact Talos
   NVIDIA extension version label, which changes on upgrade — all GPU pods
   Pending until unpinned (nvidia.tf).
5. Reboot aftershock: stale cilium state fleet-wide (dozer envoy serving
   2-day-old xDS routes to dead pod IPs; smith's eBPF service map not
   programming current endpoints -> litellm crash-looped on
   deskplane-mcp ConnectError, blocking openwebui). Fixed with a rolling
   `rollout restart daemonset cilium cilium-envoy`.
6. talos-sparks cordoned+drained: neo's reboot pushed pods onto the
   memory-starved Pi, its cilium OOM-looped (157 restarts), and the
   gateway L2 lease churned 56 times causing estate-wide 503 flaps.
   Sparks stays cordoned pending capacity review.
   **Closed 2026-08-15** — see `arm-pool-capacity-2026-08.md`. Sparks was
   healthy throughout; the cordon was live-only drift declared nowhere in
   IaC. Root cause of the OOM loop was understated platform requests
   (DaemonSets requested 689Mi/node against ~1030Mi actual) plus a
   BestEffort cilium-envoy and a request-less cilium-agent, which put the
   CNI first in the kernel OOM victim ranking. Requests are now sized from
   30d Prometheus data and sparks is back in service.

End state: all public/internal services 200, zero OOM controller triggers
on neo since the upgrade. Remaining fleet followups: ~~upgrade smith/mouse/
sparks/niobe/trinity to 1.13.2~~ (done — all 8 nodes verified on Talos
v1.13.2, 2026-08-15); ~~sparks/tank/dozer capacity~~ (done — see
`arm-pool-capacity-2026-08.md`); rewire the container-memcg-oom-loop alert
off the dead container_oom_events_total metric onto
kube_pod_container_status_last_terminated_reason.
