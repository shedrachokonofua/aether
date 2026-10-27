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

## Container registry cleanup

GitLab has no instance-wide default cleanup policy, so `gitlab.yml` installs the
user timer `gitlab-registry-cleanup-policy.timer` (daily 03:00), which pipes
`registry-cleanup-policy.rb` into `gitlab-rails runner` and applies one policy
to every project with images: run daily, keep the 5 newest tags plus `latest`, delete other
tags older than 7 days. The same run prunes build-cache repositories (`cache`
or `*/cache`) to their 5 newest tags once tags are older than 1 day, because CI
pushes one cache tag per build and project policies cannot go below 7 days.

```bash
task ansible:playbook -- gitlab/gitlab.yml --tags registry-cleanup
```

Deleting tags only removes references. Blob storage is reclaimed by the
registry's online garbage collector, which runs on the imported registry
metadata database (`registry['database']` defaults to `enabled: "prefer"`).
`gitlab.rb.j2` tunes it via `registry['gc']` (1s task interval, 6h review delay).
Apply registry config changes without recreating the pod:

```bash
task ansible:playbook -- gitlab/gitlab.yml --tags gitlab-config
# then, on the VM as aether:
podman exec gitlab gitlab-ctl reconfigure && podman exec gitlab gitlab-ctl restart registry
```
