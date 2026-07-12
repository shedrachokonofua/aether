# PaaS

Talos-based Kubernetes cluster is the application platform. Legacy
Dokku and Dokploy offerings have both been decommissioned; their
workloads were migrated onto Talos k8s.

## Kubernetes (Talos)

Talos-based Kubernetes cluster with Cilium networking, Gateway API ingress, and a growing platform layer.

### Platform Components

| Component      | Purpose                                               |
| -------------- | ----------------------------------------------------- |
| Cilium         | CNI, kube-proxy replacement, L2 LoadBalancer VIP      |
| Gateway API    | Cluster ingress via Cilium GatewayClass               |
| Ceph CSI       | RBD storage provisioning (default StorageClass)       |
| Knative        | Installed but unused; no KServices are declared        |
| OTEL Collector | Cluster + node telemetry to external monitoring stack |
| Metrics Server | metrics.k8s.io for HPA/VPA, kubectl top, Headlamp     |
| VPA Recommender | VPA recommendation engine only; updater/admission disabled |
| Goldilocks     | Resource request right-sizing dashboard for opt-in namespaces |
| Tetragon       | eBPF runtime security observability, observe-only      |
| Trivy Operator | Vulnerability/config/RBAC/security report generation   |
| Policy Reporter | UI and metrics for Kyverno and Trivy report results   |
| Kepler         | Node, pod, and container energy/efficiency metrics     |
| Headlamp       | Kubernetes dashboard with OIDC auth                   |
| Hubble UI      | Cilium network observability UI                       |
| GitLab Agent   | CI/CD deploys via GitLab KAS tunnel                   |
| Crossplane     | OIDC client control plane (Keycloak). S3/IAM moved to tofu-native 2026-07 |
| Kestra OSS     | YAML automation plane and Inquest flow runtime         |
| HolmesGPT      | Read-only Kubernetes/Prometheus/Loki investigation agent |
| Keel           | Auto-updates our GitLab `:latest` app images on new digests |
| wasmCloud      | WebAssembly component runtime (WorkloadDeployment CRs on shared hosts) |

Goldilocks is advisory only: it creates VPA objects with `updateMode: Off` in
namespaces labeled `goldilocks.fairwinds.com/enabled=true`. Resource changes
stay manual and flow back through OpenTofu. VPA reads live resource metrics from
metrics-server and uses Prometheus-backed cAdvisor history for restart/backfill
context.

Knative Serving currently has no declared consumers. A live check on 2026-07-10
found zero Knative Services while the serving and operator control planes were
still running. Keep it out of application architecture claims; its removal is a
separate IaC decision because applying that change deletes live platform
resources.

Tetragon, Trivy Operator, Policy Reporter, and Kepler are observability/reporting
components only. They do not block admissions, mutate workloads, or enforce
runtime policy.

Trivy's node collector is configured with Talos-safe host paths and small scan
job requests so per-node scans can run on the ARM pool without hard arch pins.

### Image auto-updates (Keel)

Keel (`tofu/home/kubernetes/keel.tf`, namespace `keel`) force-updates a curated
set of workloads when the digest behind their `:latest` tag changes in the
private GitLab registry. Only our own CI-built images opt in: orion, composer,
litellm's `espn-mcp` + `finviz-mcp-server` sidecars, mnemo, and deskplane
(controller + serve). Third-party `:latest` sidecars in the litellm pod are
excluded via `keel.sh/monitorContainers`.

Opt-in is per-workload metadata — `keel.sh/policy=force`, `keel.sh/trigger=poll`,
`keel.sh/matchTag=true`. Native Deployments (orion/composer/litellm) carry the
annotations inline; Helm-managed Deployments (mnemo/deskplane) get them via
`kubernetes_annotations` because their charts expose no annotation passthrough.
Keel polls every minute using each workload's existing image pull secret, so no
cluster-wide registry credential is configured.

Keel owns the running build, not OpenTofu. It keeps the image string at
`:latest` (no tofu image diff) and triggers rollouts by writing
`keel.sh/update-time` (pod template) and `kubernetes.io/change-cause`
(Deployment); both are suppressed via `lifecycle.ignore_changes` on the native
Deployments and fall outside the `kubernetes_annotations` field manager on the
Helm ones, so Keel never fights tofu. Consequence: tofu state no longer records
which digest is live, and rollback means repushing or repinning the tag rather
than a tofu revert.

Keel posts update notifications to the Apprise gateway
(`notificationLevel: success` → one message per applied update, plus failures).
Because Apprise reserves the `type` field for its severity enum and rejects
Keel's `type="deployment update"`, the endpoint remaps it to the title
(`&:type=title`) and feeds `message` to the body (`&:message=body`), routed to
the `standard` group (ntfy `/alerts` push + Matrix `#alerts`).

### WebAssembly (wasmCloud)

WebAssembly components run on the **wasmCloud runtime-operator** (Helm chart,
pinned `2.5.2`) in `wasmcloud-system`. The operator schedules components,
declared as `WorkloadDeployment` CRs (`runtime.wasmcloud.dev/v1alpha1`), onto a
small pool of shared **host pods** (`hostgroup-default`, 2 replicas). Each
component's selector-less `Service` gets an operator-managed EndpointSlice
(runtime-gateway disabled since 2.0.3); Istio Ambient provides mTLS.

**Ownership split — artifact vs deploy.** Each component repo's CI builds and
publishes the component as an **OCI `.wasm` artifact** (`wash oci push` to the
home GitLab registry). Deployment is owned by **aether tofu**, inline per
component (`Service` + `WorkloadDeployment` + optional `HTTPRoute`/trigger
`CronJob`), following the repo's inline convention (arch-labeler, node
remediator) — no shared module yet (revisit at a third component). Because
`wasmcloud-system` is platform-tier and aether-owned, project repos are
artifact factories; the deployer owns the namespace.

**Config surface (verified against the live CRD).** Component config lives under
`spec.template.spec.components[].localResources`, not a top-level env list:

- `localResources.environment.config` — literal env vars (map). Secrets/
  ConfigMaps via `environment.secretFrom` / `configFrom`.
- `localResources.allowedHosts` — outbound host allowlist for
  `wasi:http` outgoing-handler. **Without it, egress is denied** and a component
  that makes outbound calls is a silent no-op.
- `hostInterfaces` declares capability **plugins** the host wires in
  (`wasi:http` `incoming-handler` / `outgoing-handler`). `wasi:cli/environment`
  is **host-native — do NOT declare it** as a hostInterface; doing so fails the
  workload with `bind_plugins: no plugins found`. Env still arrives via
  `localResources.environment`.
- An HTTP-exposed component's `HTTPRoute` needs a `URLRewrite` filter rewriting
  the external hostname to the incoming-handler's registered host (the component
  name), on the gateway `http` section.

**Rollout.** Pin the image tag (or digest); bump + `tofu apply`; rollback =
revert. Set the component `imagePullPolicy: Always` — the wasmCloud host caches
components, so `IfNotPresent` serves stale code even on a digest bump and the
update only lands after a manual `kubectl rollout restart deploy/hostgroup-*`.
Keel cannot watch the `WorkloadDeployment` CRD and components are low-churn, so
there is no auto-roller.

Current components: `aether-wasm-hello` (canary, gateway-exposed —
`aether_wasm_hello.tf`) and `aether-comfyui-reaper` (flushes idle GPU-resident
ComfyUI model state, cron-triggered — `comfyui_reaper.tf`). Runtime owned by
`tofu/home/kubernetes/wasmcloud.tf`.

**Version note.** The runtime was migrated `2.0.5 → 2.5.2` on 2026-07-12. It is
**not a drop-in**, because the `Host` CRD scope changed `Cluster → Namespaced`
and CRD scope is immutable. The migration therefore: (1) patched the
`runtime.wasmcloud.dev/host-finalizer` off the live `Host` CRs and deleted the
old `hosts.runtime.wasmcloud.dev` CRD; (2) applied the 2.5.2 chart CRDs
out-of-band (`kubectl apply --server-side`, since Helm never upgrades `crds/`),
recreating `Host` as `Namespaced`; (3) ran the `helm upgrade` via tofu. A naive
`helm upgrade` alone crashloops the new operator (`Host is not namespaced, but
its ByObject.Namespaces setting is not nil`) against the old cluster-scoped CRD.
Hosts re-register automatically under the new CRD (`Host` now carries
`ENVIRONMENT=<namespace>`) and the operator re-places components — brief
workload unavailability, no node reboot. Repeat this CRD-first sequence for any
future scope-changing bump.

### Access

- API: `https://10.0.3.20:6443` (Talos API VIP)
- Workload VIP: `10.0.3.19` (Cilium L2 LoadBalancer IP)
- Ingress wildcard: `*.home.shdr.ch`
- Headlamp: `https://headlamp.home.shdr.ch`
- Hubble UI: `https://hubble.home.shdr.ch`
- Goldilocks: `https://goldilocks.home.shdr.ch`
- Policy Reporter: `https://policy-reporter.home.shdr.ch`
- Kestra: `https://kestra.home.shdr.ch`

Kestra's platform resources are owned by
`tofu/home/kubernetes/kestra.tf`. The automated Grafana alert workflow is owned
by sibling `../inquest`: its flow IaC creates or updates GitLab incident issues
and calls Holmes for a human-verified RCA. See `docs/monitoring.md` for the
interactive and automated investigation boundaries.
