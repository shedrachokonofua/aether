# Monitoring Agent

A simple VM monitoring agent deployed as a podman pod quadlet. It collects VM metrics and logs, and forwards them to the monitoring stack.

## Components

- Otel Collector: Collects and transforms telemetry data and forwards it to the monitoring stack.
- Node Exporter: Exports VM metrics (CPU, memory, disk, and network) for collection.
- File Log Receiver: Collects logs in `/var/log` and `/var/log/journal`.
- Journald Receiver: Collects logs from journald.

## Usage

```yaml
# playbook.yml
- hosts: home-gateway-stack
  roles:
    - monitoring_agent
```
