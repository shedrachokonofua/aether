# Kubernetes, Talos, Fleet, and SSH

## Kubernetes

Verify context before any cluster command:

```bash
nix develop -c kubectl config current-context  # admin@aether-k8s
nix develop -c .agents/skills/investigate-aether/scripts/k8s-snapshot.bb <namespace>
```

Targeted sequence:

```bash
kubectl get deploy,statefulset,daemonset,pod,job,cronjob,pvc,httproute -n <ns> -o wide
kubectl describe pod -n <ns> <pod>
kubectl get events -n <ns> --field-selector type=Warning --sort-by=.lastTimestamp
kubectl logs -n <ns> <pod> --all-containers --since=1h --timestamps
kubectl logs -n <ns> <pod> -c <container> --previous --since=1h --timestamps
```

Correlate events with readiness, restarts, and impact. The live cluster has many repeated `FailedToRetrieveImagePullSecret` warnings across otherwise healthy pods and can retain old Failed/Evicted pods. Neither is causal without matching timing and state.

Inspect CNPG, Gateway API, Cilium, and other CRDs with `kubectl explain` before assuming field shape. Do not read Kubernetes Secrets unless the investigation requires a specific field; never print secret material.

## Talos

Talos nodes do not expose normal SSH. Use `talosctl` with the repo-generated config after verifying cluster identity. Prefer Kubernetes/node metrics first, then Talos service/log APIs for node-level questions.

## Fleet

Fleet is a supplemental host-inspection surface at `https://fleet.home.shdr.ch`, not a Grafana datasource and not canonical inventory. It can show enrolled hosts, status/last seen, policies, saved queries, processes, packages, users, ports, and file events.

Coverage is partial. On 2026-07-09, nine hosts were enrolled and only three were marked online; several offline statuses had recent seen times. Always show status and last-seen timestamp together, and fall back to SSH or live APIs.

Fleet policy/query configuration is IaC in `ansible/playbooks/monitoring_stack/fleet.yml`; do not edit it in the UI during investigation.

## SSH Fallback

Check `task login:status`; refresh SSH credentials only when access requires it. Resolve hostname, user, and address from `ansible/inventory/hosts.yml` and `config/vm.yml`.

Use bounded read-only commands:

```bash
systemctl --failed
systemctl status <unit> --no-pager
journalctl -u <unit> --since '<start>' --until '<end>' --no-pager
podman ps --format json
podman logs --since 1h --timestamps <container>
df -hT
findmnt
ss -lntup
cat /proc/meminfo
```

The VM telemetry agent service is `aether-otel-collector`; inspect its journal when VM metrics/logs disappear. Minimal containers may lack ordinary tools, so use service APIs, `/proc`, or an appropriate helper pod instead of installing packages.
