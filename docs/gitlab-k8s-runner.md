# GitLab Kubernetes Runner

This repo now defines a dedicated GitLab Runner Helm release for Kubernetes-based
image builds in `tofu/home/kubernetes/gitlab_runner.tf`.

## Target State

- Runner scope: instance runner
- Runner tag: `buildah`
- `runUntagged`: `false`
- Executor: Kubernetes
- Job pod mode: privileged
- Job resource requests/limits: none
- Manager pod requests/limits: none
- Build job variable: `STORAGE_DRIVER=vfs`

## Manual GitLab Step

The GitLab runner must be created in GitLab first, because the Helm chart only
consumes the runner authentication token. Create a new instance runner in GitLab
UI with:

- Description: `k8s-runner`
- Tags: `buildah`
- Run untagged jobs: disabled
- Protected runner: disabled unless you explicitly want protected refs only

Copy the resulting runner authentication token (`glrt-...`) into
`secrets/secrets.yml` as `gitlab.runner_k8s_token`.

Example flow:

```bash
task se
# add:
# gitlab:
#   runner_k8s_token: glrt-...
```

## Deploy

Apply the Kubernetes workloads module after the secret is in place:

```bash
task tofu:apply
```

This creates:

- namespace `gitlab-runner` with privileged Pod Security admission
- secret `gitlab-runner-k8s-auth`
- Helm release `gitlab-runner-k8s`

## First Repo Patch

Move only Buildah jobs first. Leave test and tofu jobs on the existing runner
until the image-build path is stable.

Minimal `.gitlab-ci.yml` example:

```yaml
image-build:
  image: quay.io/buildah/stable
  stage: build
  tags:
    - buildah
  variables:
    STORAGE_DRIVER: vfs
  script:
    - buildah login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - buildah bud -t "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA" .
    - buildah push "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA"
```

## Verification

For the first rollout, verify all of the following in one low-risk repo:

1. The runner shows `online` in the target GitLab group.
2. Only jobs tagged `buildah` are picked up by the new runner.
3. `buildah bud` succeeds with `STORAGE_DRIVER=vfs`.
4. Pushes to `registry.gitlab.home.shdr.ch` succeed.
5. Build time and cache behavior are acceptable.

## Notes

- This intentionally does not introduce Docker-in-Docker.
- This intentionally does not move test or OpenTofu jobs yet.
- If the runner manager cannot trust `gitlab.home.shdr.ch`, add a custom CA
  secret and set `certsSecretName` in the Helm values template.
