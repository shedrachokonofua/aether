# Monitoring Agent

This role installs and configures the OpenTelemetry Collector on Linux systems to collect host metrics, journald logs, and file logs, then forwards them to an OTLP endpoint.

## Features

- Collects host metrics (CPU, memory, disk, network, etc.) directly via OTEL Collector
- Collects Podman container metrics (automatically enabled when Podman is detected)
- Collects Docker container metrics (automatically enabled when Docker is detected)
- Collects NVIDIA GPU metrics (automatically detected and installed on systems with NVIDIA GPUs)
- Collects journald logs from specified systemd units
- Collects file logs from configurable patterns
- Persistent cursor storage for reliable log collection
- Support for immutable operating systems (rpm-ostree)

## Requirements

- Systemd-based init system
- Internet access for downloading binaries
- Root/sudo access on target hosts

## Supported Distributions

- Fedora (DNF package manager)
- Debian/Ubuntu (APT package manager)
- VyOS (Debian-based, APT)
- Bazzite (immutable, rpm-ostree)
- Fedora Silverblue/Kinoite (immutable, rpm-ostree)

## Role Variables

All variables have sensible defaults defined in `defaults/main.yml`:

| Variable                              | Default                                        | Description                                    |
| ------------------------------------- | ---------------------------------------------- | ---------------------------------------------- |
| `otel_collector_version`              | `0.139.0`                                      | OpenTelemetry Collector Contrib version        |
| `otlp_endpoint`                       | `https://otel.home.shdr.ch`                    | OTLP HTTP exporter endpoint                    |
| `host_metrics_collection_interval`    | `15s`                                          | Interval for collecting host metrics           |
| `host_metrics_initial_delay`          | `1s`                                           | Initial delay before collecting metrics        |
| `podman_metrics_collection_interval`  | `15s`                                          | Interval for collecting Podman metrics         |
| `podman_metrics_initial_delay`        | `1s`                                           | Initial delay before collecting Podman metrics |
| `docker_metrics_collection_interval`  | `15s`                                          | Interval for collecting Docker metrics         |
| `docker_metrics_initial_delay`        | `1s`                                           | Initial delay before collecting Docker metrics |
| `monitoring_agent_service_user`       | `root`                                         | User for running the OTEL Collector service    |
| `monitored_systemd_units`             | See defaults                                   | List of systemd units to monitor via journald  |
| `file_log_patterns`                   | See defaults                                   | List of file patterns to collect logs from     |
| `otel_collector_binary_path`          | `/usr/local/bin/otelcol-contrib`               | Path to OTEL Collector binary                  |
| `otel_collector_config_path`          | `/etc/aether-monitoring-agent/otel-config.yml` | Path to OTEL Collector configuration           |
| `otel_collector_storage_path`         | `/var/lib/otelcol/storage`                     | Path for persistent cursor storage             |
| `prometheus_scrape_configs`           | `[]`                                           | List of Prometheus scrape configs (optional)   |
| `nvidia_gpu_exporter_version`         | `1.3.1`                                        | NVIDIA GPU Exporter version (auto-detected)    |
| `nvidia_gpu_exporter_port`            | `9835`                                         | Port for GPU exporter metrics endpoint         |
| `nvidia_gpu_exporter_scrape_interval` | `15s`                                          | Interval for scraping GPU metrics              |

## Example Playbook

Basic deployment:

```yaml
- hosts: monitoring_agents
  become: yes
  roles:
    - monitoring_agent
```

Custom configuration:

```yaml
- hosts: monitoring_agents
  become: yes
  vars:
    otlp_endpoint: https://your-endpoint.com
    host_metrics_collection_interval: 30s
    monitored_systemd_units:
      - nginx
      - postgresql
      - docker
    file_log_patterns:
      - "/var/log/nginx/*.log"
      - "/var/log/postgresql/*.log"
  roles:
    - monitoring_agent
```

With Prometheus scrape configs:

```yaml
- hosts: monitoring_agents
  become: yes
  vars:
    prometheus_scrape_configs:
      - job_name: "caddy"
        scrape_interval: 30s
        static_configs:
          - targets: ["localhost:2019"]
      - job_name: "node-exporter"
        scrape_interval: 15s
        static_configs:
          - targets: ["localhost:9100"]
            labels:
              env: "production"
  roles:
    - monitoring_agent
```

NVIDIA GPU monitoring is automatically detected - no configuration needed:

```yaml
- hosts: all_servers
  become: yes
  roles:
    - monitoring_agent
```

The role will automatically:

- Install GPU exporter on hosts with NVIDIA GPUs and nvidia-smi
- Skip GPU exporter on hosts without NVIDIA GPUs
- No manual configuration required!

## Components

### OpenTelemetry Collector Contrib

- Binary: `/usr/local/bin/otelcol-contrib`
- Service: `aether-otel-collector`
- Config: `/etc/aether-monitoring-agent/otel-config.yml`
- Storage: `/var/lib/otelcol/storage/`

### NVIDIA GPU Exporter (Auto-detected)

- Binary: `/usr/local/bin/nvidia_gpu_exporter`
- Service: `aether-nvidia-gpu-exporter`
- Metrics endpoint: `http://localhost:9835/metrics`
- User: Same as OTEL Collector (`{{ monitoring_agent_service_user }}`, default: `root`)
- Automatically installs on hosts with NVIDIA GPUs and nvidia-smi
- Skips installation gracefully if no GPU detected
- No configuration required

#### Receivers

- **hostmetrics**: Collects system metrics (CPU, memory, disk, filesystem, load, network, paging, processes, system)
- **podman**: Collects container metrics from Podman (automatically enabled when Podman is installed and socket is available)
  - Container CPU, memory, network, and disk I/O statistics
  - Container lifecycle and health check metrics
  - Excludes podman-pause containers by default
  - Requires `podman.socket` to be enabled (automatically handled by the role)
- **docker_stats**: Collects container metrics from Docker (automatically enabled when Docker is installed and socket is available)
  - Container CPU, memory, network, and disk I/O statistics
  - Requires Docker daemon to be running with accessible socket at `/var/run/docker.sock`
- **prometheus**: Scrapes Prometheus-format metrics from configured targets (optional)
  - Enabled when `prometheus_scrape_configs` is defined
  - Supports standard Prometheus scrape config options (job_name, scrape_interval, static_configs, etc.)
  - Useful for collecting metrics from services that expose Prometheus endpoints (e.g., Caddy, node_exporter)
  - Automatically includes NVIDIA GPU exporter when installed
- **journald**: Collects logs from systemd journal for specified units
- **filelog**: Collects logs from files matching specified patterns (including Podman container logs)

#### Processors

- **batch**: Groups telemetry data before exporting (batch size: 1000, timeout: 10s)
- **resource**: Adds resource attributes (hostname, OS info, service name)

#### Exporters

- **otlphttp**: Exports metrics and logs to the configured OTLP endpoint

## Directory Structure

```text
/etc/aether-monitoring-agent/
└── otel-config.yml           # OTEL Collector configuration

/var/lib/otelcol/storage/     # Persistent storage for log cursors

/usr/local/bin/
└── otelcol-contrib           # OTEL Collector binary
```

## Service Management

Check service status:

```bash
systemctl status aether-otel-collector
systemctl status aether-nvidia-gpu-exporter  # On GPU hosts
```

View logs:

```bash
journalctl -u aether-otel-collector -f
journalctl -u aether-nvidia-gpu-exporter -f  # On GPU hosts
```

Validate configuration:

```bash
/usr/local/bin/otelcol-contrib validate --config=/etc/aether-monitoring-agent/otel-config.yml
```

Restart service:

```bash
systemctl restart aether-otel-collector
```

## Immutable OS Notes

For Bazzite, Silverblue, and other rpm-ostree based systems:

- Binaries are installed to `/usr/local/bin` (writable on immutable systems)
- System dependencies installed via `rpm-ostree install --apply-live` (no reboot required)
- Service runs with appropriate permissions to access system logs and metrics

## Handlers

- `restart otel collector`: Restarts the OTEL Collector service
- `restart nvidia gpu exporter`: Restarts the NVIDIA GPU Exporter service
