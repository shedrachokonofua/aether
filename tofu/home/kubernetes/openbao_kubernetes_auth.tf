# =============================================================================
# OpenBao Kubernetes Auth for Aether ESO
# =============================================================================
# External Secrets Operator authenticates with namespace-local service account
# tokens. Each namespace gets an OpenBao role and policy scoped to only its own
# kv/aether/kubernetes/<namespace> subtree.

locals {
  openbao_kubernetes_auth_path = "kubernetes-aether"
  eso_secret_path_prefix       = "aether/kubernetes"
}

resource "vault_auth_backend" "kubernetes_aether" {
  type        = "kubernetes"
  path        = local.openbao_kubernetes_auth_path
  description = "Aether Kubernetes service-account auth for External Secrets Operator"

  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "4h"
  }
}

resource "vault_kubernetes_auth_backend_config" "aether" {
  backend = vault_auth_backend.kubernetes_aether.path

  kubernetes_host    = var.kubernetes_host
  kubernetes_ca_cert = base64decode(var.kubernetes_ca_certificate)

  token_reviewer_jwt = kubernetes_secret_v1.openbao_kubernetes_token_reviewer.data["token"]
}

resource "vault_policy" "kubernetes_namespace_external_secrets" {
  for_each = local.namespace_contract_specs

  name = "aether-k8s-${each.key}-external-secrets"

  policy = <<-EOT
    path "${var.openbao_kv_mount_path}/data/${local.eso_secret_path_prefix}/${each.key}/*" {
      capabilities = ["read"]
    }

    path "${var.openbao_kv_mount_path}/metadata/${local.eso_secret_path_prefix}/${each.key}/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "namespace_external_secrets" {
  for_each = local.namespace_contract_specs

  backend   = vault_auth_backend.kubernetes_aether.path
  role_name = "aether-k8s-${each.key}-external-secrets"

  bound_service_account_names      = [local.external_secrets_reader_service_account_name]
  bound_service_account_namespaces = [module.namespace[each.key].name]
  audience                         = local.openbao_external_secrets_audience

  token_policies = [vault_policy.kubernetes_namespace_external_secrets[each.key].name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}
