# UPS Management Stack

This playbook configures the UPS management stack virtual machine. The UPS management stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Network UPS Tools (NUT): SNMPv3-based UPS monitoring
- Nutify: Web dashboard for UPS visualization

## Usage

```bash
task configure:home:ups
```
