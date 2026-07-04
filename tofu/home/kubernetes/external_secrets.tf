# =============================================================================
# External Secrets Operator
# =============================================================================
# Installs ESO only. SecretStores and ExternalSecrets are declared separately so
# each namespace can be migrated deliberately from Terraform-managed Secrets.

locals {
  external_secrets_namespace     = module.namespace["external-secrets"].name
  external_secrets_chart_version = "2.7.0"
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
