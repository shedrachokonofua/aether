# Monitoring Agent

This role installs and configures the OpenTelemetry Collector on Linux systems to collect host metrics, journald logs, and file logs, then forwards them to an OTLP endpoint.

## Features

- Collects host metrics (CPU, memory, disk, network, etc.) directly via OTEL Collector
- Collects Podman container metrics (automatically enabled when Podman is detected)
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

| Variable                             | Default                                        | Description                                    |
| ------------------------------------ | ---------------------------------------------- | ---------------------------------------------- |
| `otel_collector_version`             | `0.139.0`                                      | OpenTelemetry Collector Contrib version        |
| `otlp_endpoint`                      | `https://otel.home.shdr.ch`                    | OTLP HTTP exporter endpoint                    |
| `host_metrics_collection_interval`   | `15s`                                          | Interval for collecting host metrics           |
| `host_metrics_initial_delay`         | `1s`                                           | Initial delay before collecting metrics        |
| `podman_metrics_collection_interval` | `30s`                                          | Interval for collecting Podman metrics         |
| `podman_metrics_initial_delay`       | `1s`                                           | Initial delay before collecting Podman metrics |
| `monitoring_agent_service_user`      | `root`                                         | User for running the OTEL Collector service    |
| `monitored_systemd_units`            | See defaults                                   | List of systemd units to monitor via journald  |
| `file_log_patterns`                  | See defaults                                   | List of file patterns to collect logs from     |
| `otel_collector_binary_path`         | `/usr/local/bin/otelcol-contrib`               | Path to OTEL Collector binary                  |
| `otel_collector_config_path`         | `/etc/aether-monitoring-agent/otel-config.yml` | Path to OTEL Collector configuration           |
| `otel_collector_storage_path`        | `/var/lib/otelcol/storage`                     | Path for persistent cursor storage             |
| `prometheus_scrape_configs`          | `[]`                                           | List of Prometheus scrape configs (optional)   |

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

Skip cleanup of old Podman setup:

```yaml
- hosts: monitoring_agents
  become: yes
  roles:
    - monitoring_agent
  tags:
    - never
    - cleanup # Will skip cleanup tasks unless explicitly called
```

## Components

### OpenTelemetry Collector Contrib

- Binary: `/usr/local/bin/otelcol-contrib`
- Service: `aether-otel-collector`
- Config: `/etc/aether-monitoring-agent/otel-config.yml`
- Storage: `/var/lib/otelcol/storage/`

#### Receivers

- **hostmetrics**: Collects system metrics (CPU, memory, disk, filesystem, load, network, paging, processes, system)
- **podman**: Collects container metrics from Podman (automatically enabled when Podman is installed and socket is available)
  - Container CPU, memory, network, and disk I/O statistics
  - Container lifecycle and health check metrics
  - Excludes podman-pause containers by default
  - Requires `podman.socket` to be enabled (automatically handled by the role)
- **prometheus**: Scrapes Prometheus-format metrics from configured targets (optional)
  - Enabled when `prometheus_scrape_configs` is defined
  - Supports standard Prometheus scrape config options (job_name, scrape_interval, static_configs, etc.)
  - Useful for collecting metrics from services that expose Prometheus endpoints (e.g., Caddy, node_exporter)
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
```

View logs:

```bash
journalctl -u aether-otel-collector -f
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

## Tags

- `cleanup`: Runs cleanup tasks for old Podman-based monitoring setup
- `cleanup-podman`: Exclusively runs Podman cleanup without installing new components

## Troubleshooting

### Service won't start

```bash
# Check logs
journalctl -u aether-otel-collector -n 50

# Verify configuration
/usr/local/bin/otelcol-contrib validate --config=/etc/aether-monitoring-agent/otel-config.yml

# Check for permission issues
ls -la /var/lib/otelcol/storage/
ls -la /var/log/journal/
```

### No data in backend

- Verify network connectivity to OTLP endpoint
- Check for TLS certificate issues if using HTTPS
- Review OTEL Collector logs for export errors
- Ensure time synchronization (NTP/chrony)
- Check that monitored systemd units exist on the system

### Podman metrics not appearing

- Verify Podman is installed: `which podman`
- Check Podman socket exists: `ls -la /run/podman/podman.sock`
- Ensure Podman socket is enabled: `systemctl status podman.socket`
- Start Podman socket if needed: `sudo systemctl start podman.socket`
- Ensure service has permissions to access Podman socket
- Verify containers are running: `podman ps`

Note: The role automatically enables the Podman socket with systemd overrides to keep it always available when Podman is installed.

### High memory usage

Adjust batch processor settings in the OTEL configuration:

```yaml
processors:
  batch:
    send_batch_size: 500 # Reduced from 1000
    timeout: 5s # Reduced from 10s
```

### Missing logs

- Verify journald is running and accessible
- Check file log patterns match actual files on the system
- Ensure the service user has read permissions for log files
- Check cursor storage directory for persistence issues

## Manual Removal

To completely remove the monitoring agent:

```bash
# Stop and disable service
systemctl stop aether-otel-collector
systemctl disable aether-otel-collector

# Remove binary
rm -f /usr/local/bin/otelcol-contrib

# Remove configuration and storage
rm -rf /etc/aether-monitoring-agent
rm -rf /var/lib/otelcol

# Remove service file
rm -f /etc/systemd/system/aether-otel-collector.service

# Reload systemd
systemctl daemon-reload
```
