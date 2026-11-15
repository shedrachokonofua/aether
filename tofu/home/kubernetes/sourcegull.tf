# =============================================================================
# Sourcegull — self-hosted code search (github.com/sourcegull/sourcegull)
# =============================================================================
# Upstream image + Helm chart, both published to ghcr.io/sourcegull (amd64
# only — pin nodeSelector on every component). Aether owns the namespace,
# CNPG cluster, encryption keys, OIDC wiring and the GitLab code host
# connection; the chart owns the workloads.
#
# GitLab: a read-only group access token (`sourcegull-reader`, read_api,
# Reporter on group `so`, expires 2027-11-15) was minted via the GitLab API
# and stored directly in OpenBao:
#   bao kv put kv/sourcegull/gitlab token=<new token>
# Rotate before expiry the same way (Site admin → Code host connections also
# emails codeHosts.tokenExpiryAlerts before it lapses).
#
# No `authorization` block on the connection: every Sourcegull user can read
# every mirrored repository. Per-user GitLab permission sync needs
# identityProvider.type "username" with an admin (sudo) token, or "oauth"
# with a GitLab sign-in provider — add it if per-repo visibility is needed.

locals {
  sourcegull_namespace     = module.namespace["sourcegull"].name
  sourcegull_host          = "sourcegull.home.shdr.ch"
  sourcegull_chart_version = "0.2.13" # Sourcegull 0.10.0
  sourcegull_cnpg          = "sourcegull-cnpg"
  sourcegull_database      = "sourcegull"
  sourcegull_db_user       = "sourcegull"
  sourcegull_db_service    = "${local.sourcegull_cnpg}-rw.${local.sourcegull_namespace}.svc.cluster.local"
  sourcegull_arch_amd64    = { "kubernetes.io/arch" = "amd64" }
  sourcegull_labels        = { app = "sourcegull" }
  # Bootstrapped the litellm-mcp service account (one-time, 2026-11-15);
  # builtin signup stays closed. Flip to true again only to mint another
  # service account.
  sourcegull_bootstrap_signup = false
}

resource "random_password" "sourcegull_database_password" {
  length  = 32
  special = false
}

resource "random_bytes" "sourcegull_encryption_key" {
  length = 32
}

# GitLab reader token (bao kv put kv/sourcegull/gitlab token=... — see header).
data "vault_kv_secret_v2" "sourcegull_gitlab" {
  mount = "kv"
  name  = "sourcegull/gitlab"
}

resource "kubernetes_secret_v1" "sourcegull_cnpg_app" {
  depends_on = [module.namespace["sourcegull"]]

  metadata {
    name      = "sourcegull-cnpg-app"
    namespace = local.sourcegull_namespace
    labels    = local.sourcegull_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.sourcegull_db_user
    password = random_password.sourcegull_database_password.result
  }
}

# Consumed by the chart via the top-level `existingSecret` (postgresql.mode=external
# reads `database-url`; encryptionKeys.source=file reads `encryption-keys`).
resource "kubernetes_secret_v1" "sourcegull_secrets" {
  depends_on = [module.namespace["sourcegull"]]

  metadata {
    name      = "sourcegull-secrets"
    namespace = local.sourcegull_namespace
    labels    = local.sourcegull_labels
  }

  type = "Opaque"
  data = {
    "database-url"    = "postgres://${local.sourcegull_db_user}:${random_password.sourcegull_database_password.result}@${local.sourcegull_db_service}:5432/${local.sourcegull_database}?sslmode=disable"
    "encryption-keys" = "k1:${random_bytes.sourcegull_encryption_key.base64}"
  }
}

resource "kubernetes_secret_v1" "sourcegull_gitlab" {
  depends_on = [module.namespace["sourcegull"]]

  metadata {
    name      = "sourcegull-gitlab"
    namespace = local.sourcegull_namespace
    labels    = local.sourcegull_labels
  }

  type = "Opaque"
  data = {
    token = data.vault_kv_secret_v2.sourcegull_gitlab.data["token"]
  }
}

resource "kubernetes_secret_v1" "sourcegull_oidc" {
  depends_on = [module.namespace["sourcegull"]]

  metadata {
    name      = "sourcegull-oidc"
    namespace = local.sourcegull_namespace
    labels    = local.sourcegull_labels
  }

  type = "Opaque"
  data = {
    "client-secret" = var.sourcegull_oauth_client_secret
  }
}

# =============================================================================
# Postgres (CNPG)
# =============================================================================

resource "kubectl_manifest" "sourcegull_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.sourcegull_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.sourcegull_cnpg
      namespace = local.sourcegull_namespace
      labels    = merge(local.sourcegull_labels, { "aether.sh/arm-ok" = "true" })
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
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
      storage = {
        size         = "20Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["sourcegull"]
      bootstrap = {
        initdb = {
          database = local.sourcegull_database
          owner    = local.sourcegull_db_user
          secret   = { name = kubernetes_secret_v1.sourcegull_cnpg_app.metadata[0].name }
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# Sourcegull (Helm) — sized for the "small" preset (<1,000 repos; the `so`
# group has ~50): one repo node, builtin PVC-backed blob store, external CNPG.
# =============================================================================

resource "helm_release" "sourcegull" {
  depends_on = [
    kubectl_manifest.sourcegull_cnpg_cluster,
    kubernetes_secret_v1.sourcegull_secrets,
    kubernetes_secret_v1.sourcegull_gitlab,
    kubernetes_secret_v1.sourcegull_oidc,
    kubernetes_manifest.main_gateway,
  ]

  name       = "sourcegull"
  repository = "oci://ghcr.io/sourcegull/charts"
  chart      = "sourcegull"
  namespace  = local.sourcegull_namespace
  version    = local.sourcegull_chart_version
  wait       = true
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    fullnameOverride = "sourcegull"
    externalURL      = "https://${local.sourcegull_host}"
    existingSecret   = kubernetes_secret_v1.sourcegull_secrets.metadata[0].name

    global = {
      defaultStorageClass = local.cnpg_storage_class
    }

    extraEnvVars = [
      {
        name = "GITLAB_TOKEN"
        valueFrom = {
          secretKeyRef = {
            name = kubernetes_secret_v1.sourcegull_gitlab.metadata[0].name
            key  = "token"
          }
        }
      },
      {
        name = "OIDC_CLIENT_SECRET"
        valueFrom = {
          secretKeyRef = {
            name = kubernetes_secret_v1.sourcegull_oidc.metadata[0].name
            key  = "client-secret"
          }
        }
      },
    ]

    config = {
      siteConfig = {
        "auth.providers" = [
          {
            type         = "openidconnect"
            issuer       = var.oidc_issuer_url
            clientID     = "sourcegull"
            clientSecret = "$${env:OIDC_CLIENT_SECRET}"
            displayName  = "Aether SSO"
            allowSignup  = true
          },
          {
            # Bootstraps one unprivileged builtin account (litellm-mcp) for
            # the LiteLLM MCP gateway's access token. No `authorization`
            # block on the GitLab connection, so any user reads every
            # mirrored repo — a non-admin service account is sufficient.
            # Flip to false once that account and its token exist.
            type        = "builtin"
            allowSignup = local.sourcegull_bootstrap_signup
          },
        ]
      }
      resources = {
        siteAdmins = [var.secrets["gitlab.root_email"]]
        connections = [{
          key         = "gitlab-home"
          kind        = "gitlab"
          displayName = "GitLab"
          config = {
            url          = "https://gitlab.home.shdr.ch"
            token        = "$${env:GITLAB_TOKEN}"
            projectQuery = ["groups/so/projects?include_subgroups=true"]
          }
        }]
      }
    }

    postgresql = {
      mode = "external"
    }

    web = {
      nodeSelector = local.sourcegull_arch_amd64
      autoscaling  = { hpa = { enabled = true, minReplicas = 2, maxReplicas = 3 } }
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    worker = {
      nodeSelector = local.sourcegull_arch_amd64
      replicaCount = 1
      resources = {
        requests = { cpu = "250m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    repo = {
      nodeSelector = local.sourcegull_arch_amd64
      replicaCount = 1
      persistence  = { size = "50Gi" }
      resources = {
        requests = { cpu = "1", memory = "3Gi" }
        limits   = { memory = "4Gi" }
      }
    }

    blobstore = {
      nodeSelector = local.sourcegull_arch_amd64
      persistence  = { size = "20Gi" }
    }

    migrate = {
      nodeSelector = local.sourcegull_arch_amd64
    }
  })]
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "sourcegull_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.sourcegull]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "sourcegull"
      namespace = local.sourcegull_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.sourcegull_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "sourcegull-web"
          port = 7080
        }]
      }]
    }
  }
}
