# Monitoring Agent

A simple VM monitoring agent deployed as a podman pod quadlet. It collects VM metrics and logs, and forwards them to the monitoring stack.

## Components

- Otel Collector: Collects and transforms telemetry data and forwards it to the monitoring stack.
- Node Exporter: Exports VM metrics (CPU, memory, disk, and network) for collection.
- System Log Receiver: Collects system logs for collection.

## Usage

```yaml
# playbook.yml
- hosts: gateway-stack
  roles:
    - monitoring_agent
```
