# Host Monitoring Agent

This role installs Prometheus exporters on Proxmox VE hosts for pull-based monitoring of physical hardware.

## Purpose

Part of a hybrid monitoring architecture where:
- **Physical hosts** expose metrics via exporters (this role)
- **Monitoring stack** scrapes metrics + uses API-based exporters for Proxmox/PBS
- **VMs** push telemetry via OTEL Collector (`vm_monitoring_agent` role)

## Exporters Installed

### Node Exporter (port 9100)
Exposes detailed OS and hardware metrics:
- CPU (per-core usage, load averages)
- Memory (usage, buffers, cache, swap)
- Disk I/O (per-device stats, queue depths)
- Network (per-interface stats, errors, drops)
- Filesystem (mount-level usage)

### SMART Exporter (port 9633)
Exposes disk health metrics:
- SMART attributes (temperature, reallocated sectors)
- Disk health status
- Power-on hours
- Read/write error counts
- SSD wear indicators

## Requirements

- Proxmox VE 7.x / 8.x (Debian-based)
- Root/sudo access
- smartmontools installed

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `node_exporter_version` | `1.8.2` | Node Exporter version |
| `node_exporter_port` | `9100` | Metrics port |
| `smartctl_exporter_version` | `0.12.0` | SMART Exporter version |
| `smartctl_exporter_port` | `9633` | Metrics port |
| `smartctl_exporter_enabled` | `true` | Enable SMART monitoring |

## Usage

Deploy to Proxmox hosts:

```yaml
- hosts: proxmox_hosts
  become: yes
  roles:
    - host_monitoring_agent
```

## Verification

```bash
# Check services
systemctl status aether-node-exporter
systemctl status aether-smartctl-exporter

# Test endpoints
curl http://localhost:9100/metrics
curl http://localhost:9633/metrics
```

## Complementary Monitoring

This role provides **host-level metrics**. Your monitoring stack should also run:
- **prometheus-pve-exporter** - VM/CT status, storage pools, cluster health via Proxmox API
- **pbs-exporter** - Backup job status, datastore usage via PBS API

Together, these provide complete infrastructure monitoring.

