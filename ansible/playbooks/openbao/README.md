# OpenBao

This playbook deploys [OpenBao](https://openbao.org/), the community-driven open-source fork of HashiCorp Vault. OpenBao runs as an unprivileged LXC on Oracle and provides:

- Secrets management (KV, database credentials, PKI, etc.)
- **Transit secrets engine for SOPS encryption** (server-side, key never leaves)
- Keycloak OIDC integration for user authentication
- step-ca TLS certificates for secure communication
- AWS KMS auto-unseal via IAM Roles Anywhere (certificate-based)

## Usage

```bash
task provision:home:openbao
```

## Sub-Playbooks

### Provision LXC

Creates the Fedora LXC container on Proxmox.

```bash
task ansible:playbook -- ./ansible/playbooks/openbao/provision_lxc.yml
```

### Bootstrap LXC

Configures SSH access and Python for Ansible.

```bash
task ansible:playbook -- ./ansible/playbooks/openbao/bootstrap_lxc.yml
```

### Deploy OpenBao

Installs OpenBao, configures TLS from step-ca, and sets up the service.

```bash
task ansible:playbook -- ./ansible/playbooks/openbao/deploy_openbao.yml
```

### Initialize OpenBao (First Time Only)

After deploying, initialize OpenBao to generate recovery keys and root token:

```bash
ssh root@10.0.2.9 'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/etc/openbao.d/tls/ca.crt bao operator init'
```

Save recovery keys to `secrets/openbao-recovery-keys.yml` and encrypt:

```bash
task sops:encrypt -- secrets/openbao-recovery-keys.yml
```

> [!CAUTION]
> This is a **one-time operation**. Recovery keys cannot be retrieved later!

### Provision AWS KMS

Deploys the AWS KMS stack for auto-unseal (requires step-ca trust anchor).

```bash
task ansible:playbook -- ./ansible/playbooks/openbao/provision_aws_kms.yml
```

## SOPS Integration

OpenBao Transit provides server-side encryption for SOPS. The encryption key never leaves OpenBao.

Transit + OIDC auth is configured via Tofu (`tofu/home/openbao_sops.tf`) during `task tofu:apply`:

- Transit secrets engine at `aether/`
- Encryption key `sops` (AES256-GCM96, non-exportable)
- OIDC auth via Keycloak
- Policy `sops` for encrypt/decrypt access

### Usage

```bash
task bao:login  # via UI at https://bao.home.shdr.ch
task sops:view -- secrets/secrets.yml
```

## Recovery

Recovery keys and root token are stored in `secrets/openbao-recovery-keys.yml` (SOPS-encrypted).

| Scenario           | Action                                                       |
| ------------------ | ------------------------------------------------------------ |
| Daily access       | `task bao:login` (OIDC via UI)                               |
| Admin/bootstrap    | Decrypt file, use `root_token`                               |
| Root token expired | Decrypt file, use `recovery_keys` to generate new root token |

```bash
# View recovery credentials
task sops:view -- secrets/openbao-recovery-keys.yml

# Generate new root token (if needed)
task bao:root-token
task bao:root-token:provide-keys  # enter 3 of 5 keys
```

## Required Secrets

In `secrets/secrets.yml`:

```yaml
openbao:
  lxc_password: "<lxc-root-password>"

step_ca:
  provisioner_password: "<machine-bootstrap-provisioner-password>"
```

In `secrets/aws/openbao-kms.yml` (created by `provision_aws_kms.yml`):

```yaml
aws_openbao_kms:
  kms_key_id: "<KMSKeyId>"
  profile_arn: "<ProfileArn>"
  role_arn: "<RoleArn>"
  trust_anchor_arn: "<TrustAnchorArn>"
  region: "us-east-1"
```
