# =============================================================================
# Daimyo dev namespace — access only
# =============================================================================
# The dev services themselves (Postgres, NATS JetStream, S3) live in the
# daimyo repo under deploy/dev and are applied by scripts/dev-native.sh from
# the Coder workspace. This file owns nothing but the workspace's right to
# manage them: a Role in daimyo-dev bound to the workspace pod's identity,
# ServiceAccount default in namespace coder. The namespace itself is the
# module.namespace["daimyo-dev"] stanza in namespace_contracts.tf.
#
# Production (namespace daimyo-system, its CNPG cluster, its NATS, its
# buckets) is unrelated and not referenced here.

resource "kubernetes_role_v1" "daimyo_dev_workspace" {
  depends_on = [module.namespace["daimyo-dev"]]

  metadata {
    name      = "daimyo-dev-workspace"
    namespace = module.namespace["daimyo-dev"].name
    labels    = { app = "daimyo-dev" }
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "endpoints", "configmaps", "secrets", "persistentvolumeclaims"]
    verbs      = ["create", "delete", "get", "list", "patch", "update", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create", "get"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets", "deployments"]
    verbs      = ["create", "delete", "get", "list", "patch", "update", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "daimyo_dev_workspace" {
  metadata {
    name      = "daimyo-dev-workspace"
    namespace = module.namespace["daimyo-dev"].name
    labels    = { app = "daimyo-dev" }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.daimyo_dev_workspace.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "coder"
  }
}
