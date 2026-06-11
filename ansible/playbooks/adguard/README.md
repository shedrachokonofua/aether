# AdGuard Home

This playbook provisions [AdGuard Home](https://adguard.com/en/adguard-home/overview.html), a DNS server with ad-blocking. AdGuard runs as two unprivileged NixOS LXCs and provides:

- Network-wide DNS ad blocking
- Local DNS resolution for home network
- DNS-over-HTTPS/TLS upstream

> [!NOTE]
> AdGuard is a **bootstrap service**—it must be running before Tofu can apply (DNS resolution required). Configuration is handled by NixOS, not Ansible.

## Instances

| Role      | Host    | IP            | Flake target          |
| --------- | ------- | ------------- | --------------------- |
| Primary   | Oracle  | 192.168.2.236 | `.#adguard`           |
| Secondary | Trinity | 192.168.2.237 | `.#adguard-secondary` |

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
│  $ task provision:adguard-secondary                                     │
│  └── Creates secondary LXC from base image, primary remains untouched   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  NixOS (repeatable)                                                     │
│  $ task configure:adguard-secondary                                     │
│  └── nixos-rebuild switch --flake .#adguard-secondary --target-host ... │
└─────────────────────────────────────────────────────────────────────────┘
```

## Usage

### First Time Setup

```bash
# 1. Build and upload the base image (one-time)
task nix:upload-lxc-image

# 2. Provision the secondary LXC first
task provision:adguard-secondary

# 3. Deploy NixOS configuration
task configure:adguard-secondary

# 4. After secondary DNS answers, apply the router config so VyOS forwards to both
task configure:router
```

### Update Configuration

After changing the shared resolver config:

```bash
task configure:adguard-secondary
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
- `nix/hosts/trinity/adguard-secondary.nix` - Secondary AdGuard host config
- `nix/hosts/common/adguard-resolver.nix` - Shared resolver settings
- `nix/modules/base.nix` - Common base config (SSH CA trust)
- `nix/modules/otel-agent.nix` - Monitoring agent

### Key Settings

| Setting       | Value                                   |
| ------------- | --------------------------------------- |
| Primary UI    | http://192.168.2.236:3000              |
| Secondary UI  | http://192.168.2.237:3000              |
| DNS           | 192.168.2.236:53, 192.168.2.237:53     |
| Upstream DNS  | Quad9 DoH, Cloudflare DoH, Google DoH  |
| DNSSEC        | Disabled                               |

## Network

| Port | Protocol | Purpose  |
| ---- | -------- | -------- |
| 22   | TCP      | SSH      |
| 53   | TCP/UDP  | DNS      |
| 3000 | TCP      | Admin UI |

AdGuard is on the gigahub network (192.168.2.0/24) so the resolver containers
can be reached directly from the management network even when VyOS is down.
