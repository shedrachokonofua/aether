# ARM pool capacity review and resource-request correction (2026-08-15)

**Scope:** the four Raspberry Pi workers `talos-mouse`, `talos-dozer`,
`talos-tank`, `talos-sparks`. **Trigger:** `talos-sparks` had been cordoned
since `2026-08-05T14:13Z` "pending capacity review"
(`talos-oom-sweeps-2026-08.md` step 6). This is that review.

---

## Verdict

**Nothing was wrong with `sparks`.** The node was healthy the whole time —
`Ready`, no pressure conditions, Talos v1.13.2, 213h uptime, zero OOM events in
`dmesg`, and the most free memory of any ARM node (2409 MB, versus 1019 MB on
mouse). It was carrying only DaemonSets because it was administratively
cordoned, and the cordon existed **nowhere in IaC** — `grep -ri 'cordon|unschedulable' tofu ansible config`
matched only a Grafana panel. It was invisible drift that no apply would ever
have restored or removed.

**The actual defect was cluster-wide dishonest resource requests**, in both
directions:

| | requested | 30d p95 actual | ratio |
|---|---|---|---|
| Platform DaemonSets, per ARM node | 689Mi | ~1030Mi | **0.67× — understated** |
| ARM-placed application containers | 5664Mi | 3910Mi | 1.45× — overstated |

The scheduler believed 1804Mi was free on a Pi when ~1473Mi actually was. It
packed accordingly, and because `cilium-envoy` and `ceph-csi-rbd-nodeplugin`
were **BestEffort** while `cilium-agent` had no memory request at all, the
kernel OOM killer's victim ranking put the CNI first. That is why 2026-08-05
took out cilium (157 restarts) and the gateway L2 lease (56 churns → estate-wide
503s) rather than a media pod. The node did not just run out of memory; it was
configured to sacrifice its own networking first.

---

## Method

Everything below is measured, not estimated. Source: Prometheus, 30d retention
(oldest block 2026-07-16), `container_memory_working_set_bytes` and
`rate(container_cpu_usage_seconds_total[5m])`, grouped per container per node.

Sizing rules, applied uniformly:

- **Memory request = ARM-pool p95, rounded up to 16Mi.** Memory is
  non-compressible and drives eviction, so the reserve must cover the ARM pool,
  which is where accounting accuracy is load-bearing. Fleet max is recorded in
  each code comment for future limit tuning.
- **CPU request = ARM-pool p50.** CPU is compressible; requests set `cpu.shares`,
  so the median is the honest figure and bursts stay burstable.
- **Application request = 30d p95 × 1.2, 32Mi floor.**
- **p95 is taken across every replica generation in the window**, not the
  currently-running pod. This mattered: sizing `coder` from the live pod alone
  gave 176Mi against a true p95 of 468Mi, and `hermes` dashboard 336Mi against
  beryl's true p95 of 718Mi.
- **No memory limit on the CNI.** Converting node memory pressure into a
  cluster-wide dataplane outage is worse than eviction.

---

## Changes applied

All via IaC (`tofu -target` apply, 26 resources; the unrelated in-flight colony
namespace work in the same working tree was deliberately excluded).

### Platform components — honest requests where there were none

| Component | was | now | evidence |
|---|---|---|---|
| `cilium-agent` | none | 416Mi / 370m | ARM p95 411Mi, fleet max 862Mi |
| `cilium-envoy` | none (BestEffort) | 96Mi / 50m | ARM p95 95Mi, fleet max 173Mi |
| `cilium-operator` | none | 208Mi / 20m | p95 201Mi |
| `hubble-relay` | none | 32Mi / 10m | p95 25Mi |
| `tetragon` | 128Mi / 50m | 272Mi / 20m | ARM p95 268Mi, fleet max 563Mi |
| `otel` daemonset collector | 64Mi / 50m | 160Mi / 420m | ARM p95 152Mi |
| `node-exporter` | 1Mi / 1m | 32Mi / 20m | ARM p95 25Mi |
| `ceph-csi-rbd` nodeplugin + provisioner | none (7 containers) | 16–80Mi each | ARM p95 12–78Mi |
| `csi-driver-nfs` node plugin | 20Mi | 48Mi | ARM p95 41Mi |
| `snapshot-controller` | none | 48Mi / 10m | ARM p95 35Mi |
| `knative-operator` webhook | 100Mi (chart default) | 240Mi | p95 188Mi, max 247Mi |

The ceph-csi-rbd chart routes plugin, liveness, and controller containers
through one `nodeplugin.plugin.resources` key, so that value is sized to the
largest of them. A post-render patch to split them was rejected.

### CPU limits that were silently throttling telemetry

Throttled fraction of CFS periods, 30d p95:

- `node-exporter`: **64–78% throttled on every node** against a 100m limit,
  despite CPU p95 of only 25m — scrape bursts blow the quota inside a 100ms
  period. Limit 100m → **500m**.
- `otel` daemonset collector: **47–70% throttled** on mouse/smith/sparks/neo
  against 500m, CPU p95 341–429m. Limit 500m → **1500m**.

### Kepler release removed outright

The `kepler` release was removed entirely rather than merely excluding it from
the ARM pool. It cost 192Mi per Pi — 7.7% of a 4GB node's allocatable — and
bought nothing there. Zero Grafana dashboards and zero alert rules had referenced
`kepler_*` (checked against all 24 provisioned dashboards and the provisioning
alert-rule API), and its ARM output was physically impossible:
`kepler_node_platform_joules_total` had dozer and tank reporting **5× the
joules of `neo`** (Ryzen 9950X + RTX Pro 6000). There was no RAPL on ARM; the
values were estimator output. The release and its ARM-excluding affinity were
removed together, so no Kepler pods remained anywhere.

### Application right-sizing

Lowered (over-requested): `radarr` 512→256Mi, `lidarr` 384→272Mi,
`nextexplorer` 256→112Mi, `bentopdf` 128→32Mi, `temporal-ui` 128→32Mi,
`memos` 128→64Mi, `miniflux` 128→64Mi, `barman-cloud` 128→64Mi,
`knative-serving` webhook 100→80Mi.

Raised (eviction bait): `hermes` 512→416Mi, `coder` 256→576Mi,
`globalping-probe` 64→224Mi, `tuliprox` 128→176Mi, `grafana-operator` 128→96Mi,
`policy-reporter` trivy plugin 128→112Mi, `net-gateway-api` webhook 20→64Mi.

`hermes` dashboard is now sized **per instance** — `beryl` 864Mi, `tungsten`
400Mi — because the two are not comparable (beryl p95 718Mi / max 869Mi versus
tungsten 323Mi / 394Mi) and they share one deployment spec. A single shared
value would either evict beryl or reserve 864Mi on a Pi for a 323Mi workload.

### Cordon removed

`kubectl uncordon talos-sparks`. This removed live-only drift; it did not
introduce any, since no IaC ever declared the cordon.

---

## Outcome

Request-to-actual ratio, measured after the change:

| node | allocatable | DS requests | app requests | total | live usage | req/live |
|---|---|---|---|---|---|---|
| mouse | 2503Mi | 1580Mi | 864Mi | 2444Mi | 1989Mi | 1.23× |
| dozer | 2655Mi | 1580Mi | 784Mi | 2364Mi | 2094Mi | 1.13× |
| tank | 2655Mi | 1580Mi | 936Mi | 2516Mi | 2027Mi | 1.24× |
| sparks | 2503Mi | 1580Mi | 256Mi | 1836Mi | 1790Mi | 1.03× |

Requests now track reality with modest headroom, versus 0.67× for the platform
layer before. `sparks` carries real work again — `miniflux`, `proxyscotch`,
`temporal-ui`, `nextcloud-redis`, and both policy-reporter plugins — and the
surplus that no longer fits on the Pis migrated to amd64 by itself, because ARM
affinity is `preferredDuringScheduling` weight 35, not required: `hermes-tungsten`,
`radarr`, `coder`, `wordpress`, `remux`, and `bentopdf` moved to `neo`/`trinity`
with no manual placement.

**The honest platform tax on a 4GB Pi is 1580Mi — 63% of allocatable**, leaving
~900Mi per node for applications. That is the real number to plan against.

---

## Placement automation: hardcoded arch pins removed

Follow-on pass the same night. The cluster has three mechanisms for deciding
what may run on the Pi pool, and the reason 30 workloads carried a hand-written
`kubernetes.io/arch = amd64` selector is that one of them was switched off and
another was never built.

**Working.** `aether-k8s-arch-labeler` is a mutating webhook that reads every
container image's manifest at admission and applies `aether.sh/arm-ok=true`
only when all images publish `linux/arm64` and the pod is under a memory cap;
Kyverno `arm-pool-guardrails` (Enforce) then refuses any binding to an
`aether.sh/node-pool=arm` node without that label plus CPU/memory requests. The
failure mode is safe — an unlabelled pod is denied, never scheduled onto the
wrong architecture. Verified live: it skipped `mingus/workers` for "does not
support target platform" and gitlab-runner for a 2Gi request over its cap.

**Was switched off.** The `descheduler` CronJob — installed with
`suspend = true` and never run in 94 days — is the ARM-pool rebalancer:
`deschedulerPolicy.nodeSelector = aether.sh/node-pool=arm`, LowNodeUtilization,
max 2 evictions per node per run, PVC-backed pods protected. It is exactly the
job that was done by hand with `kubectl rollout restart` earlier tonight.
Unsuspended, and its first run confirmed the expected no-op: all four ARM nodes
classified `overutilized`, zero underutilized, `totalEvicted=0`.

**Was never built.** `aether.shdr.ch/arch` is set to `amd64` on 7 namespaces in
`namespace_contracts.tf`, but no policy consumes it. `namespace-strategy.md`
describes it as "Kyverno mutate → nodeAffinity (replaces the arch-labeler
webhook)"; that mutation does not exist, so the label is inert today.

### Pins removed, with the evidence that disproved them

Every image below was checked with `docker manifest inspect` against the
reference the workload actually runs.

| pin | claim | finding |
|---|---|---|
| `holmesgpt.tf` | "upstream image is amd64" | false — `robustadev/holmes:0.35.0` is amd64+arm64. Depinned; the labeller then skipped it anyway on its 2Gi request and it stayed on amd64 by itself |
| `kube_state_metrics.tf` | "Pi pool is already memory-tight" | capacity reasoning, superseded by measured requests. Depinned; labelled `arm-ok` and now runs on `talos-tank` |
| `assay.tf:347`, `buzz.tf`, `cnpg_adopted.tf` ×3, `coder.tf`, `kestra.tf` ×2 | — | CNPG postgres 16.14/17.9, operator 1.29.1, barman sidecar 0.13.0 and `kestra/kestra:v1.3.9` all publish arm64. Removed |
| `knative.tf` workloads | "control plane stays on amd64" | all seven digest-pinned Knative images publish arm64 (plus arm/v7, ppc64le, s390x). Removed |
| `agent_sandbox.tf` | inherited the kata GICv3 reasoning | the *controller* is an ordinary pod that never sets `runtimeClassName`; sandbox placement comes from the kata RuntimeClass. Duplicate pin removed |
| `descheduler.tf` | "keep it off the constrained ARM pool" | image is arm64-capable, so the arch framing was wrong, but the intent is sound: the evictor must not compete for the pool it relieves. Re-expressed as `aether.sh/node-pool NotIn [arm]`, matching the policy scope below it |

Kept, with corrected comments: `assay.tf:512` (private worker image publishes a
single manifest with no platform data — arm64 unverifiable), `firecrawl.tf:179`
(private `firecrawl-cnpg` image is amd64-only), `celld.tf` (upstream ships
per-arch tags; the reference is literally `…-amd64`), and the kata RuntimeClass
selector — whose comment now states the real reason: the Pi Talos schematics do
not ship the `kata-containers` extension at all, and Pi 5 kata is deferred
pending validation, so it is not an ISA limitation.

### Pi 4 versus Pi 5, and a kubelet gotcha worth remembering

Two pins encoded genuine hardware facts but over-broadly, excluding all four
Pis for constraints only the Pi 4 generation has. MongoDB's ARM64 support
requires ARMv8.2-A and its production notes exclude the Raspberry Pi 4;
`dozer` and `tank` are Pi 5 / Cortex-A76, which implements ARMv8.2-A. So
`talos_cluster.tf` now emits `aether.sh/hardware-model` from the existing
`model` field in `config/vm.yml`, and Your-Spotify's MongoDB requires
`aether.sh/hardware-model NotIn [raspberry-pi-4]` — admitting the Pi 5s and all
amd64 nodes, excluding only the ARMv8.0 boards.

**The gotcha:** kubelet applies `--node-labels` only when it first *registers*
a Node. Adding the label to the Talos machine config propagated to the machine
config (confirmed on `talos-mouse` via `talosctl get machineconfig`) but the
Node object never gained it — and because an absent label satisfies `NotIn`,
the new constraint would have matched every node, including the two Pi 4s it
was written to exclude. It would have been a silent no-op that looked correct.
`kubernetes_labels.talos_node_hardware_model` now reconciles the label onto the
live Node objects, so machine config and API server agree without
re-registering a worker. Verified after apply: the `NotIn` selector returns 6
eligible nodes and excludes `mouse` and `sparks`.

### Reclaiming the tax that bought nothing

Depinning Knative was a mistake: its images are multi-arch, so it passed the
"is this a real capability limit" test, but the pin encoded placement policy.
19 control-plane pods spread onto the Pis and took 1180Mi to run a control
plane with zero Knative Services. Restored as `aether.sh/node-pool NotIn [arm]`
across all three install paths (operator chart, KnativeServing CR workloads,
and the two net-gateway-api Deployments from the upstream manifest).

Two DaemonSets were then removed from the pool on measured grounds:

| removed from ARM | per node | pool | evidence |
|---|---|---|---|
| `ceph-csi-cephfs` | 160Mi | 640Mi | zero CephFS volumes ever mounted on a Pi; 3 CephFS PVCs cluster-wide against 96 ceph-rbd |
| `istio-cni` + `ztunnel` | 228Mi | 912Mi | 2 ambient namespaces, 7 pods, exactly one ever on a Pi |

Dropping ztunnel needed a guard first: an ambient Pod on a node without ztunnel
keeps running and keeps serving, it just loses mTLS identity and L4 authz
silently. Two Kyverno policies now cover it — `ambient-off-arm-pool` mutates a
`NotIn [arm]` nodeAffinity onto Pods in ambient namespaces at CREATE, and
`deny-ambient-namespace-on-arm-pool` refuses the binding as a backstop.

Order matters and I got it wrong once: applying the deny before the mutation
left `wp-db` Pending for several minutes, because the scheduler kept choosing
an ARM node (it carries `arm-ok` and the pool has weight-35 preference) and
Kyverno kept rejecting the bind. A deny alone cannot redirect a scheduler.

Result: platform tax **1580Mi → 1192Mi per node** (10 DaemonSets → 7), free
application capacity across the pool **~0 → 2908Mi**.

---

## Open items

- **`sparks` ephemeral storage is its next constraint, not memory.** 25.5Gi
  allocatable on microSD versus 227Gi on mouse/tank, ~9Gi free at 65% used.
  Disk-heavy pods are a poor fit: the policy-reporter trivy plugin's init
  container downloads a ~1GB vulnerability DB on every start and took 2m2s just
  to pull its image there.
- **Transient `DiskPressure` on `talos-neo` during the rollout**, not on the
  Pis: a single sample at `2026-08-16T03:37Z` evicted six `tetragon`/`kepler`
  pods while every node pulled new images at once. Self-healed; neo sits at
  158Gi used / 95Gi free (62%), and all DaemonSets are fully ready. `trinity`
  had an identical single sample on 2026-08-14, so this looks like an imagefs
  threshold crossing under concurrent pulls rather than a capacity problem.
- **The Kepler release was removed outright because it was unconsumed
  everywhere, not just on ARM.** Nothing queried it on amd64 either; the
  dashboards and alert rules had zero consumers.
- **`csi-driver-nfs` is pinned to `master`**, not a version
  (`nfs_csi.tf:11`). Its helm timeout was raised 300s → 900s after the 8-node
  DaemonSet rollout exceeded 300s and left the release marked `failed` despite
  every pod converging.
- **Goldilocks/VPA covers no platform namespace.** `kube-system`, `system`,
  `observability`, `istio-system`, `tetragon`, and `ceph-csi-cephfs` all carry
  `goldilocks.fairwinds.com/enabled=false`, which is why the worst offenders had
  no recommendations. Enabling it there would keep these numbers current instead
  of requiring another manual sweep.
- **`arm-pool-guardrails` excludes the namespaces that caused this.** The
  Kyverno policy requires CPU+memory requests on every ARM-bound pod but
  excludes `kube-system`, `system`, and `istio-system` (`kyverno.tf:425`) — the
  exact namespaces whose pods had no requests.
- **The ARM pool is now genuinely full, and the descheduler cannot help.** Its
  first run classified all four Pis as `overutilized` (memory 99-100% of
  requests) with zero underutilized nodes, so LowNodeUtilization has nothing to
  balance against and logged "you might tune your thresholds further". It only
  becomes useful when a node frees up, a Pi is replaced, or capacity is added.
  More ARM work now needs more ARM memory, not better packing.
- **`aether.shdr.ch/arch` is inert.** Set to `amd64` on 7 namespaces with no
  policy consuming it. Either build the Kyverno mutation
  `namespace-strategy.md:137` describes, or drop the label so it stops implying
  a control that does not exist.
- **Two pins remain unverifiable.** `assay.tf:512` and `firecrawl.tf:179` hold
  amd64 pins because their private-registry images are amd64-only or publish no
  platform metadata. Publishing multi-arch builds for those would let the
  labeller take over.
