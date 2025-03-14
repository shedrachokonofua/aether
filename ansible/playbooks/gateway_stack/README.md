# Gateway Stack

This playbook is for configuring the gateway stack virtual machine. The gateway stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Adguard Home: DNS server, ad blocker, and web filter
- Unifi Network Application: Network controller for managing home wifi access point. Has a mongodb instance.
- Caddy: Reverse proxy for home network

## Usage

```bash
task configure:home:gateway
```

## Sub-Playbooks

### Deploy Unifi Network Controller

```bash
task ansible:playbook -- ./ansible/playbooks/gateway_stack/unifi/site.yml
```

### Deploy Adguard Home

```bash
task ansible:playbook -- ./ansible/playbooks/gateway_stack/adguard/site.yml
```

### Deploy Caddy

```bash
task ansible:playbook -- ./ansible/playbooks/gateway_stack/caddy/site.yml
```
