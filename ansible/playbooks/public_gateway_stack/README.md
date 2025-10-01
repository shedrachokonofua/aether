# Public Gateway Stack

This playbook is for configuring the public gateway stack VPS. The public gateway stack is an AWS Lightsail VPS running Amazon Linux 2023 that serves as a public entry point to expose specific internal home network applications to the internet. It acts as a DMZ, bridging the public internet with the private tailscale network.

The stack hosts the following applications:

- Caddy: Reverse proxy with Cloudflare DNS plugin that handles SSL/TLS termination and proxies public traffic to specific internal applications via tailscale
- Tailscale: Connects the public gateway to the private tailscale network, enabling secure access to internal applications

## Usage

```bash
task configure:aws:public-gateway
```

## Sub-Playbooks

### Deploy Tailscale

```bash
task ansible:playbook -- ./ansible/playbooks/public_gateway_stack/tailscale/site.yml
```

### Deploy Caddy

```bash
task ansible:playbook -- ./ansible/playbooks/public_gateway_stack/caddy/site.yml
```
