# Dokku

This playbook is for configuring the [Dokku](https://dokku.com) virtual machine. Dokku is a Fedora VM that hosts the Dokku PaaS platform - a self-hosted, Docker-powered Heroku alternative with Terraform support.

## Usage

```bash
task configure:home:dokku
```

## Sub-Playbooks

### Deploy Dokku

Deploys the Dokku platform with all required configurations.

```bash
task ansible:playbook -- ./ansible/playbooks/dokku/dokku.yml
```

### Deploy GitLab CI/CD Integration

Configures the GitLab CI/CD integration for Dokku deployments.

```bash
task ansible:playbook -- ./ansible/playbooks/dokku/gitlab_integration.yml
```

### Deploy Infisical

Deploys [Infisical](https://infisical.com) - an open-source secret management platform. Runs as a podman pod with PostgreSQL, Redis, and the Infisical backend.

```bash
task ansible:playbook -- ./ansible/playbooks/dokku/infisical.yml
```
