# =============================================================================
# GitLab Runner - Kubernetes Image Build Pool
# =============================================================================
# Dedicated runner for container image builds that should move off the VM-based
# Podman runner first. The instance runner itself must be created in GitLab with:
#   - run untagged jobs: enabled (lint/test/e2e that need nested privileged pods)
#   - tag list: buildah (optional explicit tag for image-build jobs)
# Executor config sets privileged=true so untagged e2e can `podman run --privileged`
# (systemd-in-container). Do not rely on a separate `privileged`-tagged runner.
# This release only consumes the runner authentication token.
#
# Express lane (2026-11-22): a second instance runner, `k8s-express`, that only
# takes jobs tagged `express` and kills any job at 10 minutes (set on the
# runner in GitLab: tag list `express`, run untagged off, maximum timeout 600).
# In a busy two hours that day, 144 of 206 jobs ran for under a minute, 54
# minutes of work in total, and waited 826 minutes behind long jobs, because
# every stage of a pipeline rejoins the same queue: BuyerFact's 10-second
# `ci:tag` waited 24 minutes at the median. Short jobs opt in with
# `tags: [express]`. The main runner also carries the `express` tag, so tagged
# jobs overflow to it and still run if this lane is down.

locals {
  gitlab_runner_namespace       = "gitlab-runner"
  gitlab_runner_release_name    = "gitlab-runner-k8s"
  gitlab_runner_secret_name     = "gitlab-runner-k8s-auth"
  gitlab_runner_auth_token      = var.secrets["gitlab.runner_k8s_token"]
  gitlab_runner_service_account = "gitlab-runner-k8s"

  gitlab_runner_express_release_name = "gitlab-runner-express"
  gitlab_runner_express_secret_name  = "gitlab-runner-express-auth"
  gitlab_runner_express_auth_token   = var.secrets["gitlab.runner_express_token"]
}


resource "kubernetes_secret_v1" "gitlab_runner_auth" {
  depends_on = [module.namespace["gitlab-runner"]]

  metadata {
    name      = local.gitlab_runner_secret_name
    namespace = module.namespace["gitlab-runner"].name
  }

  data = {
    "runner-token"              = local.gitlab_runner_auth_token
    "runner-registration-token" = ""
  }
}

resource "helm_release" "gitlab_runner" {
  depends_on = [kubernetes_secret_v1.gitlab_runner_auth, kubernetes_priority_class_v1.aether_batch]

  name             = local.gitlab_runner_release_name
  repository       = "https://charts.gitlab.io"
  chart            = "gitlab-runner"
  namespace        = module.namespace["gitlab-runner"].name
  create_namespace = false
  version          = "0.79.1"
  wait             = true
  timeout          = 300

  values = [templatefile("${path.module}/gitlab_runner.values.yaml.tftpl", {
    gitlab_url           = "https://gitlab.home.shdr.ch/"
    namespace            = module.namespace["gitlab-runner"].name
    runner_secret_name   = kubernetes_secret_v1.gitlab_runner_auth.metadata[0].name
    service_account_name = local.gitlab_runner_service_account
    runner_app_label     = local.gitlab_runner_release_name
    priority_class_name  = local.aether_priority_classes.batch
    replicas             = 8
    job_cpu_request      = "1"
    job_memory_request   = "2Gi"
  })]
}

resource "kubernetes_secret_v1" "gitlab_runner_express_auth" {
  depends_on = [module.namespace["gitlab-runner"]]

  metadata {
    name      = local.gitlab_runner_express_secret_name
    namespace = module.namespace["gitlab-runner"].name
  }

  data = {
    "runner-token"              = local.gitlab_runner_express_auth_token
    "runner-registration-token" = ""
  }
}

# Same executor configuration as the main lane (same nodes, cache, limits and
# overwrite ceilings, so a job behaves the same on either), with small
# requests: these jobs are seconds of work. The values template's comments
# describe the main lane; this lane's replica count and requests are the
# three arguments below. Changing a comment inside the template's TOML block
# changes the rendered config and restarts both lanes' managers.
#
# The requests are small so that the pod always finds a node. With 500m / 1Gi
# the lane's first three jobs sat Unschedulable for four minutes
# (2026-11-22): neo's CPU was fully requested by main-lane jobs, and trinity,
# smith and niobe were at 96-99% of memory requested, though neo used 38% of
# its memory and smith 57%. A Pending pod also counts against the lane's
# 10-minute cap.
resource "helm_release" "gitlab_runner_express" {
  depends_on = [
    kubernetes_secret_v1.gitlab_runner_express_auth,
    kubernetes_priority_class_v1.aether_batch,
    kubernetes_resource_quota_v1.gitlab_runner_namespace_quota,
  ]

  name             = local.gitlab_runner_express_release_name
  repository       = "https://charts.gitlab.io"
  chart            = "gitlab-runner"
  namespace        = module.namespace["gitlab-runner"].name
  create_namespace = false
  version          = "0.79.1"
  wait             = true
  timeout          = 300

  values = [templatefile("${path.module}/gitlab_runner.values.yaml.tftpl", {
    gitlab_url           = "https://gitlab.home.shdr.ch/"
    namespace            = module.namespace["gitlab-runner"].name
    runner_secret_name   = kubernetes_secret_v1.gitlab_runner_express_auth.metadata[0].name
    service_account_name = local.gitlab_runner_express_release_name
    runner_app_label     = local.gitlab_runner_express_release_name
    priority_class_name  = local.aether_priority_classes.batch
    replicas             = 6
    job_cpu_request      = "100m"
    job_memory_request   = "256Mi"
  })]
}
