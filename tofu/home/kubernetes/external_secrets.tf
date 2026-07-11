# =============================================================================
# External Secrets Operator
# =============================================================================
# Installs ESO only. SecretStores and ExternalSecrets are declared separately so
# each namespace can be migrated deliberately from Terraform-managed Secrets.

locals {
  external_secrets_namespace                   = module.namespace["external-secrets"].name
  external_secrets_chart_version               = "2.7.0"
  external_secrets_reader_service_account_name = "external-secrets-reader"
  openbao_token_reviewer_service_account_name  = "openbao-token-reviewer"
  openbao_external_secrets_audience            = "https://bao.home.shdr.ch"
}

resource "helm_release" "external_secrets" {
  depends_on = [module.namespace["external-secrets"]]

  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = local.external_secrets_namespace
  version    = local.external_secrets_chart_version

  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    installCRDs = true

    serviceMonitor = {
      enabled = false
    }

    resources = {
      requests = {
        cpu    = "50m"
        memory = "128Mi"
      }
      limits = {
        cpu    = "500m"
        memory = "512Mi"
      }
    }

    webhook = {
      resources = {
        requests = {
          cpu    = "25m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "250m"
          memory = "256Mi"
        }
      }
    }

    certController = {
      resources = {
        requests = {
          cpu    = "25m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "250m"
          memory = "256Mi"
        }
      }
    }
  })]
}

resource "kubernetes_service_account_v1" "openbao_kubernetes_token_reviewer" {
  depends_on = [module.namespace["external-secrets"]]

  metadata {
    name      = local.openbao_token_reviewer_service_account_name
    namespace = local.external_secrets_namespace
  }
}

resource "kubernetes_secret_v1" "openbao_kubernetes_token_reviewer" {
  depends_on = [kubernetes_service_account_v1.openbao_kubernetes_token_reviewer]

  metadata {
    name      = "${local.openbao_token_reviewer_service_account_name}-token"
    namespace = local.external_secrets_namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.openbao_kubernetes_token_reviewer.metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_cluster_role_binding_v1" "openbao_kubernetes_token_reviewer" {
  metadata {
    name = "openbao-token-reviewer"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.openbao_kubernetes_token_reviewer.metadata[0].name
    namespace = local.external_secrets_namespace
  }
}

resource "kubernetes_service_account_v1" "external_secrets_reader" {
  for_each = local.namespace_contract_specs

  depends_on = [module.namespace]

  metadata {
    name      = local.external_secrets_reader_service_account_name
    namespace = module.namespace[each.key].name
    labels = {
      "app.kubernetes.io/name"       = "external-secrets-reader"
      "app.kubernetes.io/managed-by" = "OpenTofu"
    }
  }

  lifecycle {
    # Kyverno attaches DockerHub pull secrets by namespace label. Own the
    # service account identity here, but leave registry credentials to Kyverno.
    ignore_changes = [image_pull_secret]
  }
}

resource "kubectl_manifest" "namespace_secret_store" {
  for_each = local.namespace_contract_specs

  depends_on = [
    helm_release.external_secrets,
    kubernetes_service_account_v1.external_secrets_reader,
    vault_kubernetes_auth_backend_config.aether,
    vault_kubernetes_auth_backend_role.namespace_external_secrets,
  ]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "openbao"
      namespace = module.namespace[each.key].name
      labels = {
        "app.kubernetes.io/name"       = "openbao"
        "app.kubernetes.io/managed-by" = "OpenTofu"
      }
    }
    spec = {
      provider = {
        vault = {
          server  = "https://bao.home.shdr.ch"
          path    = var.openbao_kv_mount_path
          version = "v2"
          auth = {
            kubernetes = {
              mountPath = vault_auth_backend.kubernetes_aether.path
              role      = vault_kubernetes_auth_backend_role.namespace_external_secrets[each.key].role_name
              serviceAccountRef = {
                name = kubernetes_service_account_v1.external_secrets_reader[each.key].metadata[0].name
                audiences = [
                  local.openbao_external_secrets_audience,
                ]
              }
            }
          }
        }
      }
    }
  })
}
