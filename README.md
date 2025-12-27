# Aether

IaC for my personal cloud.

## Docs

| Doc                                | Description                               |
| ---------------------------------- | ----------------------------------------- |
| [Home](docs/home.md)               | Hosts, network, storage, backups          |
| [Blueprint](docs/blueprint.md)     | Infrastructure layout and allocation      |
| [Trust Model](docs/trust-model.md) | Identity and authentication design        |
| [AWS](docs/aws.md)                 | Gateway, offsite backups, KMS, IAM, email |
| [Cloudflare](docs/cloudflare.md)   | DNS and external access                   |
| [Tailscale](docs/tailscale.md)     | Secure remote access to home network      |
| [TODOs](docs/todos.md)             | Roadmap and planned work                  |

## Dependencies

- Task
- Docker

## Toolbox

All CLI tools required to manage the cloud are included in a toolbox docker image.

### Included in toolbox docker image

- Ansible
- AWS CLI
- OpenTofu
- SOPS + Age
- step-cli
- yq
- pre-commit + gitleaks

### Usage

1. Build the docker image

   ```bash
   task build-tools
   ```

1. Use tools

   ```bash
   task ansible -- --version
   task aws -- --version
   task sops -- --version
   task tofu -- --version
   ```

## Managing secrets

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using Age keys. Configuration in `.sops.yaml` defines which files are encrypted.

### View secrets (stdout only)

```bash
task sops:view -- secrets/secrets.yml
```

### Edit secrets (safe in-memory edit)

```bash
task sops:edit -- secrets/secrets.yml
```

### Extract a single value

```bash
task sops:get -- '.db_password' secrets/secrets.yml
```

### Pre-commit hooks

This repo uses pre-commit hooks to prevent accidental secret leaks:

```bash
# Install pre-commit (first time only)
pip install pre-commit
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
1. Write the OpenTofu state config to `config/tofu-state.config`

#### Steps

1. Copy age private key to `config/age-key.txt`
1. Login to AWS (opens browser, 12h session)

   ```bash
   task aws:login
   ```

1. Run the bootstrap task

   ```bash
   task bootstrap
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
