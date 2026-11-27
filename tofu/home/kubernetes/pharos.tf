# =============================================================================
# Pharos — personal source-grounded EPUB library
# =============================================================================
# Sibling repo /Users/shdrch/projects/pharos
# (ssh://git@ssh.gitlab.home.shdr.ch:2222/so/pharos.git) owns the code, Nix
# image, Helm chart (deploy/helm/pharos) and CI; this file owns every cluster
# object around it — namespace contract (namespace_contracts.tf), data volume,
# CNPG database, secrets, registry pull identity, chart pin and private route.
# The Keycloak client lives in tofu/home/keycloak_pharos.tf.
#
# Single instance by design (one book-processing worker). Original EPUBs live
# on one RBD volume; everything derived from them (source blocks, passages,
# full-text and pgvector indexes, ideas, readings, checkpoints) lives in the
# pharos-cnpg Postgres cluster. Model access is local-only through LiteLLM (no
# cloud fallback): aether/qwen3.8-flash-next, aether/qwen3.8-flash-next:think
# and aether/qwen3-embedding:0.6b, on a scoped virtual key.
#
# DEPLOYMENT PIN: CI (so/pharos .gitlab-ci.yml) publishes the image as
# `:<8-char sha>` + `:latest` and chart `pharos` at `0.1.0-g<8-char sha>` to
# oci://registry.gitlab.home.shdr.ch/so/pharos. `pharos_chart_version` below
# pins the Deployment template/shape only; the container image tracks `:latest`
# with pullPolicy Always and is force-updated by Keel on every push to main.
# Bump `pharos_chart_version` only when chart templates change.
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

  # Chart version pins the Deployment template/shape only; the container image
  # below tracks :latest (retained by GitLab registry cleanup) and is watched by
  # Keel. Bump only when chart templates change.
  pharos_chart_version = "0.1.0-g80d47a9b"

  # In-cluster LiteLLM service (same endpoint deskplane and nextcloud use);
  # keeps model traffic off the gateway hairpin.
  pharos_litellm_api_base = "http://litellm.litellm.svc.cluster.local:4000/v1"
  pharos_oidc_issuer      = "https://auth.shdr.ch/realms/aether"
  pharos_allowed_users    = "shdrch"

  pharos_cnpg          = "pharos-cnpg"
  pharos_database      = "pharos"
  pharos_database_user = "pharos"
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

resource "random_password" "pharos_database_password" {
  length  = 32
  special = false
}

# basic-auth: CNPG bootstrap reads username/password for the database owner.
resource "kubernetes_secret_v1" "pharos_cnpg_app" {
  depends_on = [module.namespace["pharos"]]

  metadata {
    name      = "pharos-cnpg-app"
    namespace = local.pharos_namespace
    labels    = local.pharos_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.pharos_database_user
    password = random_password.pharos_database_password.result
  }
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

# The same bearer under the Daimyo org tree, for the `orion` agent's
# internal `pharos_books` http grant (Orion chart values; egress in
# daimyo.tf): the sidecar adds it when it sends pharos_import_book's file
# argument to PUT /mcp/books/<name>.
resource "vault_kv_secret_v2" "daimyo_orion_pharos_mcp" {
  mount = "kv"
  name  = "orgs/personal/pharos-mcp"
  data_json = jsonencode({
    token = random_password.pharos_mcp_token.result
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
    DATABASE_URL          = "postgresql://${local.pharos_database_user}:${random_password.pharos_database_password.result}@${local.pharos_cnpg}-rw.${local.pharos_namespace}.svc.cluster.local:5432/${local.pharos_database}"
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
# Original EPUB bytes only (the database holds everything derived from them).
# The namespace is backup=critical, so the volume snapshot scheduler
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

# --- Postgres (CNPG) ---------------------------------------------------------
# pgvector ships in the CNPG PostgreSQL image; the extension is created at
# bootstrap by the superuser so the application owner never needs it. WAL
# archiving and daily base backups go to SeaweedFS (cnpg_backups.tf).

resource "kubectl_manifest" "pharos_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubectl_manifest.cnpg_barman_object_store["pharos"],
    kubernetes_secret_v1.pharos_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.pharos_cnpg
      namespace = local.pharos_namespace
      labels    = merge(local.pharos_labels, { "aether.sh/arm-ok" = "true" })
    }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      imageName            = "ghcr.io/cloudnative-pg/postgresql:16.14"
      # No arch pin: ghcr.io/cloudnative-pg/postgresql:16.14 and the CNPG
      # sidecars publish linux/arm64. Placement is decided by
      # aether-k8s-arch-labeler + Kyverno arm-pool-guardrails.
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["pharos"]
      bootstrap = {
        initdb = {
          database = local.pharos_database
          owner    = local.pharos_database_user
          secret   = { name = kubernetes_secret_v1.pharos_cnpg_app.metadata[0].name }
          postInitApplicationSQL = [
            "CREATE EXTENSION IF NOT EXISTS vector",
          ]
        }
      }
    }
  })

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
    kubectl_manifest.pharos_cnpg_cluster,
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
      condition     = can(regex("^0\\.1\\.0-g[0-9a-f]{8}$", local.pharos_chart_version))
      error_message = "pharos_chart_version must be the published chart version 0.1.0-g<8-char commit sha> from so/pharos CI."
    }
  }

  values = [yamlencode({
    image = {
      tag        = "latest"
      pullPolicy = "Always"
    }
    existingSecret = kubernetes_secret_v1.pharos_env.metadata[0].name
    imagePullSecrets = [{
      name = kubernetes_secret_v1.pharos_registry.metadata[0].name
    }]
    persistence = {
      existingClaim = kubernetes_persistent_volume_claim_v1.pharos_data.metadata[0].name
    }
    # Secret rotation (session/MCP/OIDC/LiteLLM key) restarts the pod;
    # Keel polls :latest and rolls the Deployment on every new digest.
    deploymentAnnotations = {
      "reloader.stakater.com/auto" = "true"
      "keel.sh/policy"             = "force"
      "keel.sh/trigger"            = "poll"
      "keel.sh/matchTag"           = "true"
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
