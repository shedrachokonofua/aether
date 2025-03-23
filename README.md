# Aether

IaC for my personal cloud.

## Dependencies

- Task
- Docker

## Toolbox

All CLI tools required to manage the cloud are included in a toolbox docker image.

### Included in toolbox docker image

- Ansible
- AWS CLI
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
   task sops -- --version
   task tofu -- --version
   ```

## Managing secrets

1. Encrypt secrets

   ```bash
   task sops:encrypt secrets/<file>.yaml
   ```

1. Decrypt secrets

   ```bash
   task sops:decrypt secrets/<file>.yaml
   ```

## Deployment

### Requirements

- Full admin access to AWS Account
- Access to Home Network: 2 network interfaces required to connect to both the Bell Gigahub and VyOS virtual router
- Access to Age Private Key
- Bell PPPoE credentials

### Bootstrap

These steps set up the base infrastructure necessary for provisioning the cloud. The goal is to:

1. Deploy the bootstrap AWS IAM stack using the provided AWS credentials. This will create the Dev user and IAC role. These will be used to bootstrap the rest of the infrastructure, and for aws management from the home network.
1. Deploy the bootstrap OpenTofu backend stack. This will create the S3 bucket, KMS key, and DynamoDB table used to store the OpenTofu state.
1. Write the AWS credentials to the `secrets/aws-dev-user.env` file.
1. Write the OpenTofu state config to the `config/tofu-state.config` file.

#### Steps

1. Create a new AWS IAM user with AdministratorAccess policy, download the credentials
1. Copy age private key to `config/age-key.txt`
1. Run the bootstrap task

   ```bash
   task bootstrap -- <aws access-key-id> <aws secret-access-key>
   ```

### Provision Home Network

1. Manually apply rack switch configuration ([README](docs/home.md#rack-switch))

1. Provision router ([README](ansible/playbooks/home_router/README.md))

   ```bash
   task provision:home:router
   ```

1. Manually apply office switch configuration ([README](docs/home.md#office-switch))

### Provision Home Network File System

1. Provision NFS ([README](ansible/playbooks/network_file_system/README.md))

   ```bash
   task provision:home:nfs
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

[TODO]

## Docs

### Realms

- [Home](docs/home.md)
- [AWS](docs/aws.md)
- [GCP](docs/gcp.md)
