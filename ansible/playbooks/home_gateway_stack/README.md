# Home Gateway Stack

This playbook configures the Fedora `home-gateway-stack` VM declared in
`config/vm.yml` and provisioned by `tofu/home/gateway_stack.tf`.

Current services:

- UniFi Network Application and MongoDB
- Caddy reverse proxy
- Tailscale subnet routing
- dnsmasq for peer-tailnet split DNS
- HAProxy/WireProxy rotating SOCKS5 proxy
- VM OpenTelemetry monitoring agent

AdGuard is not part of this VM. The primary and secondary resolvers are separate
NixOS LXCs under `nix/hosts/` and deploy through `task configure:adguard*`.

## Usage

```bash
task configure:gateway
```

## Focused Configuration

```bash
task configure:caddy
task configure:dnsmasq
task ansible:playbook -- home_gateway_stack/unifi/site.yml
task ansible:playbook -- home_gateway_stack/tailscale/site.yml
task ansible:playbook -- home_gateway_stack/rotating-proxy/site.yml
```

Use Taskfile targets where available so the repository Ansible configuration and
environment are loaded.
