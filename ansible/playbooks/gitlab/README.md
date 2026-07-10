# GitLab

This playbook is for configuring the GitLab virtual machine. GitLab is a fedora vm that hosts the following applications deployed as podman quadlets:

- GitLab Community Edition(CE)

## Usage

```bash
task configure:gitlab
```

## Sub-Playbooks

### Deploy GitLab

Deploys the main GitLab CE instance with all required configurations.

```bash
task ansible:playbook -- gitlab/gitlab.yml
```

### Deploy GitLab Runners

Legacy only. The primary runner path is now the Kubernetes runner managed from
OpenTofu in `tofu/home/kubernetes`.

Configures and registers GitLab runners for CI/CD pipeline execution.

```bash
task ansible:playbook -- gitlab/runners.yml
```
