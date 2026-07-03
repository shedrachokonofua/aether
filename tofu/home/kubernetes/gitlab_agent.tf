# =============================================================================
# GitLab Agent for Kubernetes (CI/CD Deploys)
# =============================================================================
# Enables GitLab CI to deploy into the cluster via the KAS tunnel.

locals {
  gitlab_kas_address            = "wss://gitlab.home.shdr.ch/-/kubernetes-agent/"
  gitlab_agent_token            = var.secrets["gitlab.agent_token"]
  gitlab_ci_impersonation_user  = "gitlab-ci:so"
  gitlab_ci_impersonation_group = "gitlab-ci:so"

  gitlab_ci_write_api_groups = [
    "",
    "acme.cert-manager.io",
    "apps",
    "autoscaling",
    "batch",
    "cert-manager.io",
    "cilium.io",
    "coordination.k8s.io",
    "discovery.k8s.io",
    "events.k8s.io",
    "gateway.networking.k8s.io",
    "networking.k8s.io",
    "policy",
    "postgresql.cnpg.io",
    "rbac.authorization.k8s.io",
    "scheduling.k8s.io",
    "serving.knative.dev",
    "storage.k8s.io",
  ]

  gitlab_ci_read_only_api_groups = [
    "admissionregistration.k8s.io",
    "kyverno.io",
    "policies.kyverno.io",
  ]
}

resource "kubernetes_cluster_role_v1" "gitlab_agent_impersonator" {
  metadata {
    name = "gitlab-agent-impersonator"
  }

  rule {
    api_groups     = [""]
    resources      = ["users"]
    verbs          = ["impersonate"]
    resource_names = [local.gitlab_ci_impersonation_user]
  }

  rule {
    api_groups     = [""]
    resources      = ["groups"]
    verbs          = ["impersonate"]
    resource_names = [local.gitlab_ci_impersonation_group]
  }
}

resource "kubernetes_cluster_role_v1" "gitlab_ci_deployer" {
  metadata {
    name = "gitlab-ci-so-deployer"
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = local.gitlab_ci_write_api_groups
    resources  = ["*"]
    verbs      = ["create", "update", "patch", "delete", "deletecollection"]
  }

  rule {
    api_groups = local.gitlab_ci_read_only_api_groups
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "gitlab_ci_deployer" {
  metadata {
    name = "gitlab-ci-so-deployer"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.gitlab_ci_deployer.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = local.gitlab_ci_impersonation_group
  }
}

resource "helm_release" "gitlab_agent" {
  depends_on = [helm_release.cilium, kubernetes_cluster_role_v1.gitlab_agent_impersonator]

  name             = "gitlab-agent"
  repository       = "https://charts.gitlab.io"
  chart            = "gitlab-agent"
  namespace        = "gitlab-agent"
  version          = "2.22.1"
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [yamlencode({
    config = {
      token      = local.gitlab_agent_token
      kasAddress = local.gitlab_kas_address
      operational_container_scanning = {
        enabled = false
      }
    }
    rbac = {
      useExistingRole = kubernetes_cluster_role_v1.gitlab_agent_impersonator.metadata[0].name
    }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
    }
  })]
}

