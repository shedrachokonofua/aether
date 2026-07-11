# Investigation Playbooks

## Application Down

1. Check Home dashboard, active alerts, and blackbox `probe_success`.
2. Map hostname to Caddy/Gateway/HTTPRoute and runtime.
3. Check workload/service endpoint readiness.
4. Query Loki for the affected service and window.
5. Check dependency metrics/logs: database, storage, DNS, identity, upstream API.
6. Verify directly with a safe health/version/request endpoint.

Completion: identify the first failed dependency or state transition and explain downstream symptoms.

## CPU, Memory, Disk, or GPU Alert

1. Confirm metric semantics, labels, resource limit/capacity, and alert window.
2. Compare short and longer range; identify when the slope changed.
3. Attribute to host, VM, pod, container, device, or process.
4. Correlate workload/log/deployment activity.
5. Check pressure, throttling, queueing, I/O, and missing telemetry before blaming utilization alone.

Completion: quantify magnitude/duration and name the responsible workload or remaining attribution gap.

## Failed Kubernetes Deployment

1. Verify context and desired/available replicas.
2. Inspect the specific pod and recent namespace/object warnings.
3. Read current and previous container logs with timestamps.
4. Check PVC, scheduling, image, secret, route, and dependency state.
5. Compare with the declared image/config and recent diff.

Completion: distinguish rollout blocker from unrelated global warnings or old failed pods.

## Missing Telemetry

1. Check Grafana and datasource health.
2. Check Prometheus active target health or Loki query readiness.
3. Inspect central OTel accepted/refused/export-failure metrics.
4. Inspect the relevant Kubernetes collector or `aether-otel-collector` journal.
5. Verify exporter/socket/log-path configuration against IaC.

Completion: locate the break at producer, agent, transport, central collector, backend, or query layer.

## Network or DNS Failure

1. Resolve the hostname through the client-intended resolver and compare public/internal answers.
2. Map VLAN, firewall zone, route, Caddy/Gateway, and upstream endpoint.
3. Query Prometheus for probe/proxy/network failures.
4. Use ClickHouse for connection/DNS/IDS evidence and Loki/host logs for proxy/router services.
5. Check whether identity or CrowdSec symptoms are masquerading as network failure.

Completion: identify the failing hop and preserve public-versus-private DNS intent.

## Backup Failure

1. Inspect the operation/job ID, state, start time, percent, bytes/files, and lock state.
2. Check current backup alerts and last-success metrics.
3. Read the exact job/service logs for the same attempt.
4. Verify source health, target reachability/capacity, credentials, retention, and interruption/restart timing.
5. Separate live data storage from the backup interface and offsite copy.

Completion: state whether data is protected now, what scope is stale, and what restore evidence exists.

## Authentication Failure

1. Identify the boundary: browser, reverse proxy, Keycloak, app callback, token exchange, SSH cert, Bao, AWS, or GCP.
2. Check `task login:status` without refreshing everything.
3. Correlate rendered route/client config with Keycloak/app/proxy logs.
4. Distinguish authentication, redirect, authorization, DNS, and certificate failures.

Completion: name the failing exchange and the authoritative configuration that controls it.

## Inquest Pipeline or Incident Follow-Up

1. Start from the Grafana alert fingerprint and `so/aether/incidents` issue
   timeline; distinguish Grafana facts, Kestra state, Holmes analysis, and human
   comments.
2. Run `grafana-read.bb contact-points` and confirm the alert's contact point has
   an `inquest-*` receiver without exposing its URL key.
3. Match the fingerprint and timestamps to the `aether.inquest/alert-intake`
   and `process-alert` Kestra executions.
4. If the pipeline succeeded, independently verify the Holmes RCA through
   Grafana and the smallest relevant live surface.
5. If the pipeline failed, locate the first failed hop: Grafana delivery,
   intake fan-out, Kestra subflow, GitLab issue API, Holmes request, or Apprise
   notification. Do not trigger, retry, or edit anything during diagnosis.

Completion: state separately whether the infrastructure incident is understood,
whether the automated pipeline worked, and whether the Holmes RCA is confirmed.
