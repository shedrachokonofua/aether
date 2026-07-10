# Loki Logs and Tempo Traces

## Loki

Query Loki through Grafana and always bound time, labels, and result count.

```bash
G=.agents/skills/investigate-aether/scripts/grafana-read.bb
nix develop -c "$G" loki-labels
nix develop -c "$G" loki-label service_namespace
nix develop -c "$G" loki '{service_namespace="mnemo"} |= "error"'
```

Current indexed discovery labels are:

- `service_name`, `service_namespace`
- `k8s_cluster_name`, `k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name`
- internal `__stream_shard__`

Do not start VM queries with `job` or `unit`; those are not indexed Loki labels here. Begin with `service_name=<inventory name>`, then filter parsed fields or text. VM journald records may include `journald_unit_name`, priority, syslog identifier, container name, `host_name`, and OS attributes as structured metadata/body fields.

Kubernetes examples:

```logql
{k8s_namespace_name="cnpg-system", k8s_container_name="manager"} |= "error"
{service_namespace="mnemo"} | json | level=~"error|fatal"
sum by (service_name) (count_over_time({service_namespace="mnemo"} |= "error" [5m]))
```

Loki is high-volume. Avoid broad selectors such as `{service_name=~".+"}` for raw retrieval. Retention is 90 days. Retry readiness briefly before declaring it down; then prove a query failure.

## Tempo

Tempo has no public DNS by design. The Grafana datasource injects the required `X-Scope-OrgID: aether` tenant header.

```bash
G=.agents/skills/investigate-aether/scripts/grafana-read.bb
nix develop -c "$G" tempo-services
nix develop -c "$G" tempo '{ resource.service.name = "mnemo" }'
nix develop -c "$G" tempo-trace '<trace-id>'
```

Useful API paths behind the Grafana proxy:

- `/api/search?limit=<n>&q=<TraceQL>`
- `/api/v2/search/tags`
- `/api/v2/search/tag/resource.service.name/values`
- `/api/traces/<trace-id>`

Trace coverage is application opt-in, not infrastructure-wide. As verified on 2026-07-09, current service discovery returned only Mnemo traces. Re-discover before every investigation and report absence as a coverage limitation. Tempo retention is seven days.

Sources: central `otel_config.yml.j2`, `tempo.yml`, Grafana datasource provisioning, and application OTel configuration.
