# =============================================================================
# Pharos — personal source-grounded EPUB library
# =============================================================================
# Sibling repo /Users/shdrch/projects/pharos
# (ssh://git@ssh.gitlab.home.shdr.ch:2222/so/pharos.git) owns the code, Nix
# image, Helm chart (deploy/helm/pharos) and CI; this file owns every cluster
# object around it — namespace contract (namespace_contracts.tf), data volume,
# secrets, registry pull identity, chart pin and private route. The Keycloak
# client lives in tofu/home/keycloak_pharos.tf.
#
# Single instance by design (SQLite/WAL + one book-processing worker on one
# RBD volume). Model access is local-only through LiteLLM (no cloud fallback):
# aether/qwen3.8-flash-next, aether/qwen3.8-flash-next:think and
# aether/qwen3-embedding:0.6b, on a scoped virtual key.
#
# DEPLOYMENT PIN: CI (so/pharos .gitlab-ci.yml chart-publish) publishes chart
# `pharos` at version 0.1.0-<8-char commit sha> to
# oci://registry.gitlab.home.shdr.ch/so/pharos, and the published chart's
# values pin the image to the same sha. Set pharos_chart_version below to that
# version after the sibling repo publishes; the placeholder is rejected by the
# release precondition so it cannot be applied by accident.
#
# PREREQUISITES outside this file (parent-owned, see completion notes):
#   - SOPS key litellm.virtual_keys.pharos (secrets/secrets.yml), registered by
#     ansible/playbooks/register_litellm_virtual_keys.yml with the model
#     allowlist below.
#   - variable pharos_oauth_client_secret wired from keycloak_openid_client.pharos.

locals {
  pharos_namespace = module.namespace["pharos"].name
  pharos_host      = "pharos.home.shdr.ch"
  pharos_base_url  = "https://${local.pharos_host}"
  pharos_labels = {
    app                         = "pharos"
    "app.kubernetes.io/name"    = "pharos"
    "app.kubernetes.io/part-of" = "pharos"
  }

  # Published by so/pharos CI from main (98439b44): image and chart pinned to the same commit.
  pharos_chart_version = "0.1.0-98439b44"

  # In-cluster LiteLLM service (same endpoint deskplane and nextcloud use);
  # keeps model traffic off the gateway hairpin.
  pharos_litellm_api_base = "http://litellm.litellm.svc.cluster.local:4000/v1"
  pharos_oidc_issuer      = "https://auth.shdr.ch/realms/aether"
  pharos_allowed_users    = "shdrch"
}

# --- Generated application secrets -------------------------------------------
# Distinct from each other and from the OIDC client secret: the session secret
# signs browser cookies, the MCP token is the bearer credential for /mcp.

resource "random_password" "pharos_session_secret" {
  length  = 64
  special = false
}

resource "random_password" "pharos_mcp_token" {
  length  = 64
  special = false
}

# The MCP client credential must be retrievable by the operator without
# reading cluster Secrets: bao kv get -field=token kv/pharos/mcp
resource "vault_kv_secret_v2" "pharos_mcp" {
  mount = "kv"
  name  = "pharos/mcp"
  data_json = jsonencode({
    token = random_password.pharos_mcp_token.result
    url   = "${local.pharos_base_url}/mcp"
  })
}

resource "kubernetes_secret_v1" "pharos_env" {
  depends_on = [module.namespace["pharos"]]

  metadata {
    name      = "pharos-env"
    namespace = local.pharos_namespace
    labels    = local.pharos_labels
  }

  type = "Opaque"
  data = {
    LITELLM_API_KEY       = var.secrets["litellm.virtual_keys.pharos"]
    OIDC_CLIENT_SECRET    = var.pharos_oauth_client_secret
    PHAROS_SESSION_SECRET = random_password.pharos_session_secret.result
    PHAROS_MCP_TOKEN      = random_password.pharos_mcp_token.result
  }
}

# --- GitLab registry pull identity -------------------------------------------

resource "kubernetes_secret_v1" "pharos_registry" {
  depends_on = [module.namespace["pharos"]]

  metadata {
    name      = "pharos-gitlab-registry"
    namespace = local.pharos_namespace
    labels    = local.pharos_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.gitlab_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

# --- Persistent data ---------------------------------------------------------
# Original EPUBs, SQLite database, search/vector data and stage artifacts. The
# namespace is backup=critical, so the volume snapshot scheduler
# (external_snapshotter.tf) takes daily crash-consistent RBD snapshots (7 kept).

resource "kubernetes_persistent_volume_claim_v1" "pharos_data" {
  depends_on = [module.namespace["pharos"]]

  metadata {
    name      = "pharos-data"
    namespace = local.pharos_namespace
    labels    = local.pharos_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- Helm release ------------------------------------------------------------

resource "helm_release" "pharos" {
  depends_on = [
    kubernetes_secret_v1.pharos_env,
    kubernetes_secret_v1.pharos_registry,
    kubernetes_persistent_volume_claim_v1.pharos_data,
    helm_release.reloader,
  ]

  name       = "pharos"
  repository = "oci://${local.gitlab_registry_host}/so/pharos"
  chart      = "pharos"
  version    = local.pharos_chart_version
  namespace  = local.pharos_namespace
  wait       = true
  atomic     = true
  timeout    = 600

  lifecycle {
    precondition {
      condition     = can(regex("^0\\.1\\.0-[0-9a-f]{8}$", local.pharos_chart_version))
      error_message = "pharos_chart_version must be the published chart version 0.1.0-<8-char commit sha> from so/pharos CI."
    }
  }

  values = [yamlencode({
    existingSecret = kubernetes_secret_v1.pharos_env.metadata[0].name
    imagePullSecrets = [{
      name = kubernetes_secret_v1.pharos_registry.metadata[0].name
    }]
    persistence = {
      existingClaim = kubernetes_persistent_volume_claim_v1.pharos_data.metadata[0].name
    }
    # Secret rotation (session/MCP/OIDC/LiteLLM key) restarts the pod.
    deploymentAnnotations = {
      "reloader.stakater.com/auto" = "true"
    }
    config = {
      baseUrl         = local.pharos_base_url
      authRequired    = true
      oidcIssuer      = local.pharos_oidc_issuer
      oidcClientId    = "pharos"
      allowedUsers    = local.pharos_allowed_users
      litellmApiBase  = local.pharos_litellm_api_base
      model           = "aether/qwen3.8-flash-next"
      reasoningModel  = "aether/qwen3.8-flash-next:think"
      embeddingModel  = "aether/qwen3-embedding:0.6b"
      maxSectionChars = 16000
      modelTimeout    = 600
    }
  })]
}

# --- Private route -----------------------------------------------------------
# *.home.shdr.ch internal listener; the namespace's exposure=internal gives it
# gateway-access. Authentication is the application's own Keycloak OIDC
# session plus the separate MCP bearer token.

resource "kubernetes_manifest" "pharos_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.pharos]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "pharos"
      namespace = local.pharos_namespace
      labels    = local.pharos_labels
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.pharos_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "pharos"
          port = 8080
        }]
      }]
    }
  }
}
