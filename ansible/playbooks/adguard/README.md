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
│  Base Image (build once)                                                │
│  $ task nix:upload-lxc-image                                            │
│  └── Builds NixOS LXC image with SSH CA trust baked in                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Ansible (one-time setup)                                               │
│  $ task provision:adguard                                               │
│  └── Creates LXC from base image, SSH works immediately                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  NixOS (repeatable)                                                     │
│  $ task configure:adguard                                               │
│  └── nixos-rebuild switch --flake .#adguard --target-host root@...      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Usage

### First Time Setup

```bash
# 1. Build and upload the base image (one-time)
task nix:upload-lxc-image

# 2. Provision the LXC
task provision:adguard

# 3. Deploy NixOS configuration
task configure:adguard
```

### Update Configuration

After changing `nix/hosts/oracle/adguard.nix`:

```bash
task configure:adguard
```

### Rebuild LXC (if needed)

```bash
task provision:adguard
task configure:adguard
```

## NixOS Configuration

The actual AdGuard configuration lives in:

- `nix/hosts/oracle/adguard.nix` - AdGuard-specific config
- `nix/modules/base.nix` - Common base config (SSH CA trust)
- `nix/modules/otel-agent.nix` - Monitoring agent

### Key Settings

| Setting      | Value                      |
| ------------ | -------------------------- |
| Admin UI     | http://192.168.2.236:3000  |
| DNS          | 192.168.2.236:53           |
| Upstream DNS | Cloudflare DoH, Google DoH |
| DNSSEC       | Enabled                    |

## Network

| Port | Protocol | Purpose  |
| ---- | -------- | -------- |
| 22   | TCP      | SSH      |
| 53   | TCP/UDP  | DNS      |
| 3000 | TCP      | Admin UI |

AdGuard is on the gigahub network (192.168.2.0/24) so it's available even when VyOS is down.
