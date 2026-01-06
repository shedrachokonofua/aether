# Monitoring Stack

This playbook will configure the monitoring stack virtual machine. The monitoring stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Otel Collector
- Prometheus
- Loki
- Tempo
- Grafana

## Usage

```bash
task configure:home:monitoring
```
