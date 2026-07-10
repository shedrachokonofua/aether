---
name: investigate-aether
description: Interactively investigate Aether outages, alerts, regressions, performance issues, failed deployments, missing telemetry, backup failures, authentication problems, and network/security questions using live read-only evidence, including human follow-up on an Inquest incident. Use Grafana as the primary correlation surface across Prometheus metrics, Loki logs, Tempo traces, ClickHouse Zeek/Suricata data, Kubernetes state, Fleet, Talos, SSH, and service APIs. This is not the unattended Grafana-to-Kestra-to-Holmes-to-GitLab pipeline owned by sibling ../inquest; consume its incident record when present, independently verify its RCA, and stop before remediation or live mutation.
---

# Investigate Aether

Investigate from current evidence, not repository speculation. Start narrow, correlate independent sources, and remain read-only.

## Read First

- Read the root `AGENTS.md` for shell, authentication, Kubernetes-context, and live-patching rules.
- Use `$navigate-aether` if runtime, placement, or ownership is unclear.
- Read only the source reference needed for the next question:
  - [Grafana](references/grafana.md): dashboards, alerts, datasource discovery, API access.
  - [Prometheus](references/prometheus.md): metrics, targets, labels, retention, known metric families.
  - [Loki and Tempo](references/loki-tempo.md): logs, traces, indexed labels, coverage limits.
  - [Kubernetes and hosts](references/kubernetes-hosts.md): cluster events/logs, Talos, Fleet, SSH.
  - [Network security](references/network-security.md): ClickHouse, Zeek, Suricata, Hubble, Tetragon.
  - [Inquest](references/inquest.md): automated alert intake, incident correlation, and pipeline-failure follow-up.
  - [Investigation playbooks](references/playbooks.md): common symptom-to-evidence paths.

## Inquest Boundary

- Sibling `../inquest` owns unattended alert intake, severity gating,
  fingerprint dedupe, Kestra flows, the GitLab `so/aether/incidents` lifecycle,
  and the Holmes call. Aether owns the platform and integration those flows use.
- This skill is the human-invoked read-only path. For an Inquest alert or issue,
  start with its fingerprint and issue timeline, treat the Holmes comment as an
  untrusted hypothesis, then corroborate it with live evidence.
- Do not create, update, or close Inquest issues; invoke or retry Holmes; or
  rerun/test Kestra flows unless the user explicitly asks to operate or debug
  Inquest. A pipeline failure itself may still be investigated read-only.

## Investigation Workflow

### 1. Frame the question

Record:

- affected component and user-visible impact
- expected behavior
- first and last known timestamps with timezone
- relevant change/deployment window
- whether the request is diagnosis-only or includes remediation

Use absolute timestamps in findings. Begin with a short range around the event and expand only when evidence requires it.

### 2. Verify access and target

```bash
nix develop -c task login:status
nix develop -c kubectl config current-context
```

Check Kubernetes context only for cluster work; it must be `admin@aether-k8s`. Do not refresh otherwise-working credentials preemptively. Resolve host aliases and addresses from inventory/shared config, never memory.

`task login` is the unified AWS, Google WIF, OpenBao, Ceph RGW, and SSH flow. Use `task login -- --ssh` when only the SSH certificate is missing. Use `task k8s:auth` only to repair wrong/stale Kubernetes or Talos configuration because it overwrites local kubeconfig and talosconfig.

### 3. Start at Grafana

1. Check Grafana health.
2. Search dashboards and inspect the closest existing dashboard.
3. Summarize active alerts; identify the intentional `DeadMansSwitch` separately.
4. Discover datasource UIDs dynamically.
5. Query one backend selected by the symptom.

Use the tested read-only helper from the repo root:

```bash
nix develop -c .agents/skills/investigate-aether/scripts/grafana-read.bb health
nix develop -c .agents/skills/investigate-aether/scripts/grafana-read.bb dashboards
nix develop -c .agents/skills/investigate-aether/scripts/grafana-read.bb alerts
```

Do not fan out across every datasource before forming a hypothesis.

### 4. Select evidence

| Question | First evidence | Corroborate with |
| --- | --- | --- |
| Availability or saturation | Prometheus/Grafana dashboard | Loki, Kubernetes, SSH/service API |
| Application error | Loki | Prometheus, Tempo, Kubernetes state |
| Cross-service latency | Tempo when instrumented | Prometheus latency plus Loki |
| Failed Kubernetes rollout | Workload status and targeted events | Loki/pod logs, Prometheus restarts |
| VM/LXC/host failure | Prometheus/PVE metrics | SSH journal, systemd, Podman, Fleet |
| Network or IDS question | ClickHouse Zeek/Suricata | Hubble/Tetragon, DNS/proxy logs |
| Backup failure | Operation/API and backup metrics | job logs, storage/lock state |
| Missing data | target and collector health | exporter/agent logs and live endpoint |
| Inquest incident follow-up | GitLab incident issue and fingerprint | Grafana alert plus independent live telemetry |

Missing telemetry is an evidence gap, not proof of recovery or inactivity.

### 5. Correlate a timeline

For every claimed cause, capture at least two of:

- a state transition or alert timestamp
- a metric change over the same window
- a matching log/event/trace
- a failed dependency or endpoint
- a deployment/configuration change

Treat old failed pods, high-volume logs, repeated image-pull-secret warnings, and persistent security review alerts as possible background noise until they match impact and timing.

### 6. Stop before mutation

Investigation commands are read-only. Do not patch, restart, roll out, apply, delete, mute, acknowledge, or change dashboards/alerts. If remediation is requested, present the IaC path and follow root `AGENTS.md`; any live patch still requires explicit approval with command, impact, rollback, and verification.

## Output Contract

Lead with the current state and root cause:

```markdown
## Current State
## Impact
## Timeline
## Evidence
## Root Cause
## Secondary Symptoms
## Confidence and Gaps
## Recommended IaC Remediation
## Verification Plan
```

For a health/status request, give the concise status first. State which live surfaces were queried and which were unavailable. Never include tokens, decrypted secrets, credentials, or unnecessary sensitive log payloads.
