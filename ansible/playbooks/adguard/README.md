# AdGuard Home

This playbook provisions [AdGuard Home](https://adguard.com/en/adguard-home/overview.html), a DNS server with ad-blocking. AdGuard runs as an unprivileged NixOS LXC on Oracle and provides:

- Network-wide DNS ad blocking
- Local DNS resolution for home network
- DNS-over-HTTPS/TLS upstream

> [!NOTE]
> AdGuard is a **bootstrap service**—it must be running before Tofu can apply (DNS resolution required). Configuration is handled by NixOS, not Ansible.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Ansible (one-time setup)                                               │
│  ├── provision_lxc.yml    → Create NixOS LXC via pct                    │
│  └── bootstrap_lxc.yml    → Configure SSH CA trust via pct exec         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  NixOS (repeatable)                                                     │
│  $ task deploy:adguard                                                  │
│  └── nixos-rebuild switch --flake .#adguard --target-host root@...      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Usage

### Full Provision (new LXC)

```bash
# 1. Provision + bootstrap LXC
task provision:adguard

# 2. Deploy NixOS configuration
task configure:adguard
```

### Update Configuration

After changing `nix/hosts/oracle/adguard.nix`:

```bash
task configure:adguard
```

## Sub-Playbooks

### provision_lxc.yml

Creates the NixOS LXC container on Proxmox.

```bash
ansible-playbook ansible/playbooks/adguard/provision_lxc.yml
```

### bootstrap_lxc.yml

Configures SSH access with CA trust so `nixos-rebuild` can connect.

```bash
ansible-playbook ansible/playbooks/adguard/bootstrap_lxc.yml
```

## NixOS Configuration

The actual AdGuard configuration lives in:

- `nix/hosts/oracle/adguard.nix` - AdGuard-specific config
- `nix/modules/lxc-base.nix` - Common LXC config (SSH, OTEL, packages)

### Key Settings

| Setting      | Value                      |
| ------------ | -------------------------- |
| Admin UI     | http://192.168.2.236:3000  |
| DNS          | 192.168.2.236:53           |
| Upstream DNS | Cloudflare DoH, Google DoH |
| DNSSEC       | Enabled                    |

## Required Secrets

```yaml
adguard:
  lxc_password: "<lxc-root-password>"
```

## Network

| Port | Protocol | Purpose  |
| ---- | -------- | -------- |
| 22   | TCP      | SSH      |
| 53   | TCP/UDP  | DNS      |
| 3000 | TCP      | Admin UI |

AdGuard is on the gigahub network (192.168.2.0/24) so it's available even when VyOS is down.
