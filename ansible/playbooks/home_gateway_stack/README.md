# Gateway Stack

This playbook is for configuring the gateway stack virtual machine. The gateway stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- Adguard Home: DNS server, ad blocker, and web filter
- Unifi Network Application: Network controller for managing home wifi access point. Has a mongodb instance.
- Caddy: Reverse proxy for home network
- Tailscale Subnet Router: Gateway between the home network and the tailscale network.

## Usage

```bash
task configure:home:gateway
```

## Sub-Playbooks

### Deploy Unifi Network Controller

```bash
task ansible:playbook -- ./ansible/playbooks/home_gateway_stack/unifi/site.yml
```

### Deploy Adguard Home

```bash
task ansible:playbook -- ./ansible/playbooks/home_gateway_stack/adguard/site.yml
```

### Deploy Caddy

```bash
task ansible:playbook -- ./ansible/playbooks/home_gateway_stack/caddy/site.yml
```

### Deploy Tailscale Subnet Router

```bash
task ansible:playbook -- ./ansible/playbooks/home_gateway_stack/tailscale/site.yml
```

### Deploy Rotating Proxy

```bash
task ansible:playbook -- ./ansible/playbooks/home_gateway_stack/rotating-proxy/site.yml
```
