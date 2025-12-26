# OpenBao

This playbook deploys [OpenBao](https://openbao.org/), the community-driven open-source fork of HashiCorp Vault. OpenBao runs as an unprivileged LXC on Oracle and provides:

- Secrets management (KV, database credentials, PKI, etc.)
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

### Provision AWS KMS

Deploys the AWS KMS stack for auto-unseal (requires step-ca trust anchor).

```bash
task ansible:playbook -- ./ansible/playbooks/openbao/provision_aws_kms.yml
```

## Required Secrets

```yaml
openbao:
  lxc_password: "<lxc-root-password>"
  # AWS KMS auto-unseal via IAM Roles Anywhere
  aws_kms_key_id: "<KMSKeyId>"
  aws_profile_arn: "<ProfileArn>"
  aws_role_arn: "<RoleArn>"
  aws_trust_anchor_arn: "<TrustAnchorArn>"
  aws_region: "us-east-1"
```
