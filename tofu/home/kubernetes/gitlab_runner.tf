# =============================================================================
# GitLab Runner - Kubernetes Image Build Pool
# =============================================================================
# Dedicated runner for container image builds that should move off the VM-based
# Podman runner first. The instance runner itself must be created in GitLab with:
#   - run untagged jobs: enabled
#   - tag list: buildah
# This release only consumes the runner authentication token.

locals {
  gitlab_runner_namespace       = "gitlab-runner"
  gitlab_runner_release_name    = "gitlab-runner-k8s"
  gitlab_runner_secret_name     = "gitlab-runner-k8s-auth"
  gitlab_runner_auth_token      = var.secrets["gitlab.runner_k8s_token"]
  gitlab_runner_service_account = "gitlab-runner-k8s"
}

resource "kubernetes_namespace_v1" "gitlab_runner" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.gitlab_runner_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "kubernetes_secret_v1" "gitlab_runner_auth" {
  depends_on = [kubernetes_namespace_v1.gitlab_runner]

  metadata {
    name      = local.gitlab_runner_secret_name
    namespace = kubernetes_namespace_v1.gitlab_runner.metadata[0].name
  }

  data = {
    "runner-token"              = local.gitlab_runner_auth_token
    "runner-registration-token" = ""
  }
}

resource "helm_release" "gitlab_runner" {
  depends_on = [kubernetes_secret_v1.gitlab_runner_auth]

  name             = local.gitlab_runner_release_name
  repository       = "https://charts.gitlab.io"
  chart            = "gitlab-runner"
  namespace        = kubernetes_namespace_v1.gitlab_runner.metadata[0].name
  create_namespace = false
  version          = "0.79.1"
  wait             = true
  timeout          = 300

  values = [templatefile("${path.module}/gitlab_runner.values.yaml.tftpl", {
    gitlab_url           = "https://gitlab.home.shdr.ch/"
    namespace            = kubernetes_namespace_v1.gitlab_runner.metadata[0].name
    runner_secret_name   = kubernetes_secret_v1.gitlab_runner_auth.metadata[0].name
    service_account_name = local.gitlab_runner_service_account
    runner_app_label     = local.gitlab_runner_release_name
  })]
}
