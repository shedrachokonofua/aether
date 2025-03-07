# Gateway Stack

This playbook is for configuring the gateway stack virtual machine. The gateway stack is a fedora vm that hosts the following applications:

- Caddy[[Link](https://hub.docker.com/_/caddy)]: Reverse proxy for home network
- Unifi Network Application + MongoDB[[Link](https://hub.docker.com/r/linuxserver/unifi-network-application)]: Network controller for managing home wifi access point
- Adguard Home[[Link](https://hub.docker.com/r/adguard/adguardhome)]: DNS server, ad blocker, and web filter

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
task ansible:playbook -- ./ansible/playbooks/gateway_stack/adguard.yml
```

### Deploy Caddy

```bash
task ansible:playbook -- ./ansible/playbooks/gateway_stack/caddy/site.yml
```
