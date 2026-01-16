# =============================================================================
# GitLab Agent for Kubernetes (CI/CD Deploys)
# =============================================================================
# Enables GitLab CI to deploy into the cluster via the KAS tunnel.

locals {
  gitlab_kas_address = "wss://gitlab.home.shdr.ch/-/kubernetes-agent/"
  gitlab_agent_token = var.secrets["gitlab.agent_token"]
}

resource "helm_release" "gitlab_agent" {
  depends_on = [helm_release.cilium]

  name             = "gitlab-agent"
  repository       = "https://charts.gitlab.io"
  chart            = "gitlab-agent"
  namespace        = "gitlab-agent"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [yamlencode({
    config = {
      token      = local.gitlab_agent_token
      kasAddress = local.gitlab_kas_address
    }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
    }
  })]
}

