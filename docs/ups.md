# UPS

Uninterruptible power supply management for the home rack.

## Hardware

CyberPower UPS connected via USB to the rack switch for network monitoring.

## Software Stack

| Component         | Purpose                      |
| ----------------- | ---------------------------- |
| Network UPS Tools | UPS monitoring daemon (upsd) |
| Peanut            | Web dashboard for NUT        |
| NUT Exporter      | Prometheus metrics for NUT   |

## Network Configuration

The UPS is connected to the rack switch on port 4 (VLAN 1, Gigahub network) for network monitoring. NUT runs in Kubernetes as `infra/ups-management` and reaches the UPS management card through the Services-to-MGMT router rule.

## Monitoring

UPS metrics are scraped by Prometheus and displayed in Grafana:

- Input/output voltage
- Battery charge level
- Load percentage
- Runtime remaining
- UPS status (online, on battery, low battery)

## Alerting

Grafana alerts configured for:

- UPS on battery
- Low battery (<20%)
- High load (>80%)
- UPS offline

## Graceful Shutdown

NUT is configured to initiate graceful shutdown of VMs when battery reaches critical level, ensuring clean shutdown before power loss.
