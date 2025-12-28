# UPS

Uninterruptible power supply management for the home rack.

## Hardware

CyberPower UPS connected via USB to the rack switch for network monitoring.

## Software Stack

| Component         | Purpose                      |
| ----------------- | ---------------------------- |
| Network UPS Tools | UPS monitoring daemon (upsd) |
| Peanut            | Web dashboard for NUT        |
| SNMP Exporter     | Prometheus metrics via SNMP  |

## Network Configuration

The UPS is connected to the rack switch on port 4 (VLAN 1, Gigahub network) for SNMP access. NUT runs on the UPS Management Stack VM (Niobe) and communicates over the network.

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
