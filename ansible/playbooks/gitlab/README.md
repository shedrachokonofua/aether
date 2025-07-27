# GitLab

This playbook is for configuring the GitLab virtual machine. GitLab is a fedora vm that hosts the following applications deployed as podman quadlets:

- GitLab Community Edition(CE)
- GitLab Runners: CI/CD runners for executing pipeline jobs

## Usage

```bash
task configure:home:gitlab
```

## Sub-Playbooks

### Deploy GitLab

Deploys the main GitLab CE instance with all required configurations.

```bash
task ansible:playbook -- ./ansible/playbooks/gitlab/gitlab.yml
```

### Deploy GitLab Runners

Configures and registers GitLab runners for CI/CD pipeline execution.

```bash
task ansible:playbook -- ./ansible/playbooks/gitlab/runners.yml
```
