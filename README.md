# Aether

IaC for my personal cloud.

## Prequisites

- Task
- Docker

## Toolbox

All CLI tools required to manage the cloud are included in a toolbox docker image.

### Included in toolbox docker image

- Ansible
- AWS CLI
- Cloud-Init
- OpenTofu
- Sops

### Usage

1. Build the docker image

```bash
task build-tools
```

1. Use tools

```bash
task ansible -- --version
task aws -- --version
task cloud-init -- --version
task sops -- --version
task tofu -- --version
```

## Bootstrap

1. Create a new AWS account
1. Create a new IAM user with AdministratorAccess policy, download the credentials
1. Copy age private key to `config/age-key.txt`
1. Run the bootstrap task

```bash
task bootstrap -- <aws access-key-id> <aws secret-access-key>
```
