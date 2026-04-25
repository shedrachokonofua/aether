# GitLab Kubernetes Runner

This repo now defines a dedicated GitLab Runner Helm release for Kubernetes-based
image builds in `tofu/home/kubernetes/gitlab_runner.tf`.

## Target State

- Runner scope: instance runner
- Runner tag: `buildah` (optional selector only)
- `runUntagged`: `true`
- Executor: Kubernetes
- Job pod mode: privileged
- Manager replicas: `3`
- Max concurrent jobs: `1` per manager, `3` total
- Manager pod requests/limits: `100m`/`500m` CPU, `128Mi`/`512Mi` memory
- Build container requests/limits: `2`/`2` CPU, `2Gi`/`4Gi` memory,
  `8Gi`/`32Gi` ephemeral storage
- Helper and service container requests/limits: small bounded defaults
- Default build storage driver: `STORAGE_DRIVER=overlay`

## Manual GitLab Step

The GitLab runner must be created in GitLab first, because the Helm chart only
consumes the runner authentication token. Create a new instance runner in GitLab
UI with:

- Description: `k8s-runner`
- Tags: `buildah`
- Run untagged jobs: enabled
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

For targeted rollout after changing only runner settings:

```bash
task tofu:apply:gitlab-runner
```

## First Repo Patch

Move only Buildah jobs first. Leave test and tofu jobs on the existing runner
until the image-build path is stable.

Minimal `.gitlab-ci.yml` example without a tag requirement:

```yaml
image-build:
  image: quay.io/buildah/stable
  stage: build
  script:
    - buildah login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - buildah bud -t "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA" .
    - buildah push "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA"
```

If you still want to pin a job to this runner explicitly, you can keep:

```yaml
tags:
  - buildah
```

## Verification

For the first rollout, verify all of the following in one low-risk repo:

1. The runner shows `online` in the target GitLab group.
2. Untagged Buildah jobs are picked up by the new runner.
3. `buildah bud` succeeds with `STORAGE_DRIVER=overlay`.
4. Pushes to `registry.gitlab.home.shdr.ch` succeed.
5. Build time and cache behavior are acceptable.

## Notes

- This intentionally does not introduce Docker-in-Docker.
- This intentionally does not move test or OpenTofu jobs yet.
- Existing jobs that explicitly set `STORAGE_DRIVER=vfs` must remove that
  override or change it to `overlay`; job-level variables can override the
  runner default.
- The runner is intentionally capped below the observed cluster pain point of
  6-7 concurrent jobs. With three manager replicas and a per-runner limit of
  one job, this release should run at most three builds at a time.
- Build jobs can request more resources with Kubernetes executor variables, but
  the runner caps overrides at `4` CPU, `8Gi` memory, and `64Gi` ephemeral
  storage.
- If the runner manager cannot trust `gitlab.home.shdr.ch`, add a custom CA
  secret and set `certsSecretName` in the Helm values template.
