# UPS Management Stack

This playbook configures the UPS management stack virtual machine. The UPS management stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Network UPS Tools (NUT): SNMPv3-based UPS monitoring
- [PeaNUT](https://github.com/Brandawg93/PeaNUT): A tiny dashboard for Network UPS Tools
- [NUT Exporter](https://github.com/DRuggeri/nut_exporter): Prometheus exporter for Network UPS Tools

## Usage

```bash
task configure:home:ups
```
