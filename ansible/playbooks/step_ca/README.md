# step-ca

This playbook deploys [step-ca](https://smallstep.com/docs/step-ca), a private Certificate Authority. step-ca runs as an unprivileged LXC on Oracle and provides:

- SSH certificates (host and user)
- X.509 certificates for mTLS
- Keycloak OIDC integration for user authentication

## Usage

```bash
task provision:home:step-ca
```

## Sub-Playbooks

### Provision LXC

Creates the Fedora LXC container on Proxmox.

```bash
task ansible:playbook -- ./ansible/playbooks/step_ca/provision_lxc.yml
```

### Bootstrap LXC

Configures SSH access and Python for Ansible.

```bash
task ansible:playbook -- ./ansible/playbooks/step_ca/bootstrap_lxc.yml
```

### Deploy step-ca

Installs step-ca, initializes the PKI, and configures provisioners.

```bash
task ansible:playbook -- ./ansible/playbooks/step_ca/deploy_step_ca.yml
```

## Provisioners

| Name                | Type   | Purpose                     |
| ------------------- | ------ | --------------------------- |
| `machine-bootstrap` | JWK    | VM/container enrollment     |
| `keycloak`          | OIDC   | User auth → SSH/X.509 certs |
| `sshpop`            | SSHPOP | SSH cert renewal            |

## Required Secrets

```yaml
step_ca:
  lxc_password: "<lxc-root-password>"
  password: "<ca-key-password>"
  provisioner_password: "<jwk-provisioner-password>"
```
