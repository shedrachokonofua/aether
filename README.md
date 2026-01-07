# Aether

IaC for my private cloud.

## Features

- **Infrastructure as Code**: Provisioning and configuration with Ansible, OpenTofu, and Packer
- **Compute**: Proxmox VE cluster (5 nodes, 400GB RAM, 100 vCPUs) with HA failover for Ceph-backed VMs
- **Application Containers**: Rootless Podman Quadlets (systemd-native), Docker only for where Podman is not feasible
- **Networking**: VyOS router with zone-based firewall, 3Gbps symmetric WAN, 10Gbps backbone, VLAN segmentation, AdGuard DNS, Tailscale mesh, rotating VPN SOCKS5 proxy
- **Public Gateway**: Selective internet exposure via Cloudflare DNS/CDN, AWS Lightsail DMZ + CrowdSec WAF, proxied home via Tailscale mesh
- **Storage**: ZFS + Ceph with NFS/SMB/CephFS, 3-2-1 backups via Restic to Glacier
- **Security**: Private PKI (step-ca), Keycloak SSO, mTLS, OpenBao secrets, SOPS with multi-key encryption
- **DevOps**: GitLab (VCS, CI/CD, registries, Terraform state), Dokku/Dokploy/Smallweb PaaS, Coder workspaces
- **AI & ML**: Private LLM inference (Ollama, LiteLLM, OpenWebUI), Stable Diffusion (ComfyUI, SwarmUI) on RTX Pro 6000 Max-Q
- **Observability**: Prometheus/Grafana, Loki, Tempo, OTEL Collector, NUT
- **Communications**: Matrix homeserver with bridges, ntfy/Apprise notifications, Postfix relay via SES
- **Smart Home**: Home Assistant with Z-Wave and Thread/Matter
- **Entertainment**: Cloud gaming via Bazzite + Sunshine (RTX 1660 Super passthrough), Jellyfin media

## Docs

### Infrastructure

| Doc                                          | Description                          |
| -------------------------------------------- | ------------------------------------ |
| [Hosts](docs/hosts.md)                       | Proxmox cluster nodes and host roles |
| [Virtual Machines](docs/virtual-machines.md) | VM/LXC allocation and resource usage |
| [Networking](docs/networking.md)             | VLANs, firewall, DNS, reverse proxy  |
| [Storage](docs/storage.md)                   | Ceph, ZFS, NFS, CephFS               |
| [Backups](docs/backups.md)                   | 3-2-1 strategy, PBS, Restic to S3    |
| [UPS](docs/ups.md)                           | Uninterruptible power supply         |
| [NixOS](docs/nixos.md)                       | Declarative OS configuration         |

### Security & Identity

| Doc                                | Description                             |
| ---------------------------------- | --------------------------------------- |
| [Trust Model](docs/trust-model.md) | Identity planes and auth architecture   |
| [Secrets](docs/secrets.md)         | OpenBao, SOPS, encryption key hierarchy |

### Services

| Doc                                    | Description                            |
| -------------------------------------- | -------------------------------------- |
| [AI/ML](docs/ai-ml.md)                 | GPU workstation, Ollama, LiteLLM, RAG  |
| [PaaS](docs/paas.md)                   | Dokku, Dokploy, Smallweb               |
| [Monitoring](docs/monitoring.md)       | OTEL, Prometheus, Grafana, Loki, Tempo |
| [Communication](docs/communication.md) | Matrix, ntfy, Postfix, bridges         |

### External

| Doc                              | Description                       |
| -------------------------------- | --------------------------------- |
| [AWS](docs/aws.md)               | Public gateway, backups, KMS, IAM |
| [Cloudflare](docs/cloudflare.md) | DNS and CDN                       |
| [Tailscale](docs/tailscale.md)   | Secure remote access via mesh VPN |

### Meta

| Doc                    | Description              |
| ---------------------- | ------------------------ |
| [TODOs](docs/todos.md) | Roadmap and planned work |

## Dependencies

- [Nix](https://nixos.org/) (provides all tools via `nix develop`)

## Toolbox

All CLI tools are provided by the Nix flake. Enter the dev shell to get:

- Ansible
- AWS CLI
- OpenTofu
- SOPS + Age
- OpenBao CLI
- step-cli
- jq, yq
- pre-commit + gitleaks

### Usage

```bash
# Enter dev shell (or use direnv)
nix develop

# Tools are now available directly
tofu --version
ansible --version
aws --version
sops --version
```

## Managing secrets

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using a three-tier key hierarchy:

1. **Primary**: OpenBao Transit (server-side encryption, key never leaves OpenBao)
2. **Fallback**: AWS KMS (when OpenBao unavailable)
3. **Emergency**: Age key (offline, works when everything else is down)

### Unified Login

Single SSO login via Keycloak device auth:

```bash
# Login once - opens browser to auth.shdr.ch, gets: SSH cert + OpenBao token + AWS creds
task login

# Check auth status
task login:status

# View/edit secrets (shortcuts: sv, se, sg, sl)
task sv              # view secrets/secrets.yml
task se              # edit secrets/secrets.yml
task sg -- '.path'   # get single value
task sl              # list all keys
```

### Standalone/Fallback workflows

```bash
# Separate service logins
step ssh login --provisioner=keycloak  # SSH certificate (step-ca)
# OpenBao: login at https://bao.home.shdr.ch, token auto-cached

# Age key (bootstrap or emergency)
# Write Age key to config/age-key.txt, use SOPS, then remove
task sv
rm config/age-key.txt
```

### Rotating keys

Re-encrypt all secrets with current keys from `.sops.yaml`:

```bash
task login
task sops:rotate
```

### Disaster recovery

The Age key is the master key that can decrypt everything:

```
Age Key → decrypts → Recovery Keys → unseals → OpenBao → unlocks → Everything
```

The Age key is **not stored on disk** normally. For bootstrap or emergencies:

1. Write key to `config/age-key.txt`
2. Perform recovery operations
3. Remove `config/age-key.txt` when done

**Keep the Age key backed up offline** (printed, USB in safe, etc.)

### Pre-commit hooks

This repo uses pre-commit hooks to prevent accidental secret leaks:

```bash
# Install hooks (first time only)
pre-commit install

# Run manually
pre-commit run --all-files
```

## Deployment

### Requirements

- Full admin access to AWS Account
- Access to Home Network: 2 network interfaces required to connect to both the Bell Gigahub and VyOS virtual router
- Access to Age Private Key
- Bell PPPoE credentials

### Bootstrap

These steps set up the base infrastructure necessary for provisioning the cloud. The goal is to:

1. Deploy the OpenTofu backend stack (S3 bucket, KMS key, DynamoDB table for state)
1. Create SOPS KMS key for fallback encryption
1. Write the OpenTofu state config to `config/tofu-state.config`

#### Steps

1. Login (opens browser, gets AWS + OpenBao + SSH creds)

   ```bash
   task login
   ```

1. Run the bootstrap task

   ```bash
   task bootstrap
   ```

1. Verify SOPS KMS key was created

   ```bash
   aws kms describe-key --key-id alias/aether-sops
   ```

### Provision Home Network

1. Manually apply rack switch configuration ([README](docs/home.md#rack-switch))

1. Provision router ([README](ansible/playbooks/home_router/README.md))

   ```bash
   task provision:home:router
   ```

1. Manually apply office switch configuration ([README](docs/home.md#office-switch))

### Provision Home Network File System

1. Provision NFS ([README](ansible/playbooks/network_file_server/README.md))

   ```bash
   task provision:home:nfs
   ```

### Provision Certificate Authority ([README](ansible/playbooks/step_ca/README.md))

```bash
task provision:home:step-ca
```

### Provision OpenBao ([README](ansible/playbooks/openbao/README.md))

```bash
task provision:home:openbao
```

After first-time init, save recovery keys to `secrets/openbao-recovery-keys.yml` and encrypt:

```bash
sops -e -i secrets/openbao-recovery-keys.yml
```

SOPS Transit + OIDC auth is configured during `task tofu:apply` (bootstrap with root token, then revoke):

```bash
# First time only: use root token to bootstrap OIDC
export VAULT_ADDR=https://bao.home.shdr.ch
export VAULT_TOKEN=<root-token>
task tofu:apply
bao token revoke -self  # revoke root token after bootstrap
```

### Provision Keycloak ([README](ansible/playbooks/keycloak/README.md))

```bash
task provision:home:keycloak
```

### Provision Infrastructure

#### Inspect changes

```bash
task tofu:plan
```

#### Apply changes

```bash
task tofu:apply
```

### Configure Infrastructure

```bash
task configure
```
