# Prometheus Metrics

Prometheus is reached through the Grafana datasource proxy. Query target/collector health before interpreting absent series.

## Helper

```bash
G=.agents/skills/investigate-aether/scripts/grafana-read.bb
nix develop -c "$G" prom-targets
nix develop -c "$G" prom 'count by (job) (up)'
nix develop -c "$G" prom-label job
nix develop -c "$G" prom-range 'sum by (job) (rate(scrape_samples_scraped[5m]))'
```

The range helper defaults to the last hour. Pass Unix seconds for explicit start/end timestamps.

## Current Collection Paths

Direct central scrape jobs declared in `prometheus.yml.j2` include:

- `prometheus`, `otel-collector`, `otel-metrics`
- `proxmox-hosts-node`, `proxmox-hosts-smart`, `proxmox-cluster`
- `proxmox-backup`, `ceph`
- `blackbox-tls`, `blackbox-http-apps`

`otel-metrics` is one central endpoint aggregating metrics pushed by VM and Kubernetes collectors. Its `up` series describe downstream scrape targets and must not be read as many direct central targets.

## Starting Queries

```promql
count by (job) (up)
probe_success{job="blackbox-http-apps"} == 0
topk(15, sum by (service_namespace, service_name) (k8s_pod_cpu_utilization))
topk(15, sum by (service_namespace, service_name) (k8s_pod_memory_working_set))
sum by (service_namespace, service_name) (increase(k8s_container_restarts[1h])) > 0
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
rate(node_disk_read_bytes_total[5m])
rate(node_disk_written_bytes_total[5m])
100 * pve_cpu_usage_ratio{id=~"node/.*"}
pve_cpu_usage_ratio{id=~"qemu/.*|lxc/.*"} / pve_cpu_usage_limit
time() - barman_cloud_cloudnative_pg_io_last_available_backup_timestamp
```

For `node/*`, `pve_cpu_usage_ratio` is already a host utilization ratio; multiply
by 100 for percent and corroborate with node-exporter idle counters. For
`qemu/*` and `lxc/*`, the usage value behaves like consumed cores in this
environment, so divide by `pve_cpu_usage_limit` for percent of assigned vCPUs.

## Labels and Cardinality

Discover labels for the metric/time window instead of assuming consistency. Common labels include `job`, `instance`, `host_name`, `service_name`, `service_namespace`, `namespace`, `pod`, and Kubernetes resource labels.

Historical `service_name` values include churned pod names and are high-cardinality. Narrow by current namespace/pod, a metric name, and a bounded range before enumerating them.

## Retention and Blind Spots

- Central scrape interval is normally 30 seconds; SMART is 60 seconds.
- Prometheus retention is 15 days in the current deployment.
- VM agents collect host, container, local Prometheus, journald, and file telemetry, but configuration varies per host.
- Missing a metric may mean collector/exporter failure, label drift, expiration, or no instrumentation.
- Use Proxmox history or longer-lived ClickHouse aggregates for questions beyond Prometheus retention.

Source paths: `ansible/playbooks/monitoring_stack/prometheus.yml.j2`, `otel_config.yml.j2`, VM monitoring role, Nix OTel module, and `tofu/home/kubernetes/otel_collector.tf`.
