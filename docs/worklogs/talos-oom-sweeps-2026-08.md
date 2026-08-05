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

- Audit remaining unlimited pods on neo/dozer (`kubectl get pods -A -o json |
  jq '.., qosClass'` for BestEffort on those nodes) — same fix shape.
- dozer/sparks/tank report 101–109% memory in `kubectl top` — genuine
  overcommit, separate from this mechanism.
- Consider scraping PSI + alerting on `oomactions` (restart-loop alerts fired
  for days without paging anyone at severity).
- talos-neo runs Talos v1.12.1 (fleet has 1.13.2); 1.12.x is the release line
  with the known aggressive-OOM reports. Upgrade with the normal Talos flow.
- postgrest (vc-seven30, 237 restarts/day) has the classic memcg OOM loop —
  owned by the seven30 tenant repo, needs its limit raised there.
