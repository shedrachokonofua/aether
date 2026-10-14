# =============================================================================
# Orion — personal AI dashboard / start page (home.shdr.ch)
# =============================================================================
# SvelteKit (adapter-node) + Drizzle on Postgres. Image is autobuilt by GitLab
# CI from the orion repo (registry.gitlab.home.shdr.ch/so/orion/<branch>).
# Postgres is a CNPG cluster (orion-cnpg) with barman backups via
# cnpg_backup_targets["orion"]; Orion runs its Drizzle migrations at startup
# under an advisory lock, so rolling deploys are safe.
# Auth is real Keycloak OIDC (realm: aether, client: orion) — no bypass in prod.
#
# Apex host home.shdr.ch is routed via a dedicated main-gateway listener
# ("home-root" in gateway.tf) since the *.home.shdr.ch wildcard does not match
# the bare apex.

locals {
  # Pinned to the dev/revamp build (Postgres + new shell) until it merges to
  # main; keel only follows digests of this exact tag, so it stays put.
  orion_image            = "registry.gitlab.home.shdr.ch/so/orion/dev-revamp:bb4ad81595b1b13ff15939f00ef3aa27637a41b1"
  orion_host             = "home.shdr.ch"
  orion_port             = 3000
  orion_ns               = module.namespace["orion"].name
  orion_labels           = { app = "orion" }
  orion_registry_host    = "registry.gitlab.home.shdr.ch"
  orion_registry_user    = var.secrets["gitlab.root_email"]
  orion_registry_pass    = var.secrets["gitlab.root_password"]
  orion_cnpg             = "orion-cnpg"
  orion_database         = "orion"
  orion_database_user    = "orion"
  orion_database_service = "${local.orion_cnpg}-rw.${local.orion_ns}.svc.cluster.local"
}

# Pull secret for the private GitLab registry (same creds as composer/open-design).
resource "kubernetes_secret_v1" "orion_gitlab_registry" {
  depends_on = [module.namespace["orion"]]

  metadata {
    name      = "orion-gitlab-registry"
    namespace = local.orion_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.orion_registry_host) = {
          username = local.orion_registry_user
          password = local.orion_registry_pass
          auth     = base64encode("${local.orion_registry_user}:${local.orion_registry_pass}")
        }
      }
    })
  }
}

# Session signing key — generated and held in tofu state (like openwebui's
# postgres password). Rotating it invalidates active sessions, which is fine.
resource "random_password" "orion_session_secret" {
  length  = 48
  special = true
}

# Encrypts users' stored Keycloak refresh tokens (Orion threads reach Daimyo
# as the user via token exchange). Rotating it forces everyone to sign in again.
resource "random_bytes" "orion_token_encryption_key" {
  length = 32
}

# Env vars sourced from tofu state + the OIDC client secret var. The OIDC
# client secret is passed down from the parent module (see talos_cluster.tf).
locals {
  orion_env = {
    OIDC_ISSUER        = "https://auth.shdr.ch/realms/aether"
    OIDC_CLIENT_ID     = "orion"
    OIDC_CLIENT_SECRET = var.orion_oauth_client_secret
    OIDC_REDIRECT_URI  = "https://${local.orion_host}/auth/callback"
    OIDC_SCOPE         = "openid profile email"
    SESSION_SECRET     = random_password.orion_session_secret.result
    DATABASE_URL       = "postgresql://${local.orion_database_user}:${random_password.orion_database_password.result}@${local.orion_database_service}:5432/${local.orion_database}?sslmode=disable"
    # Threads → the `orion` Daimyo agent, as the signed-in user (keycloak.tf
    # orion client: token exchange to aud `daimyo`).
    DAIMYO_URL           = "https://daimyo.home.shdr.ch"
    TOKEN_ENCRYPTION_KEY = random_bytes.orion_token_encryption_key.base64
    # News widget → self-hosted Miniflux (API key minted in Miniflux, stored in SOPS).
    MINIFLUX_URL     = "https://miniflux.home.shdr.ch"
    MINIFLUX_API_KEY = var.secrets["miniflux.orion_api_key"]
    # LLM + web search → LiteLLM and SearXNG over cluster DNS (hairpin via the
    # LAN Caddy VM removed per namespace-strategy §8.2 / answer-engine Slice 13).
    LITELLM_URL     = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
    LITELLM_API_KEY = var.secrets["litellm.virtual_keys.orion"]
    SEARXNG_URL     = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.searxng_ns}.svc.cluster.local:${local.searxng_port}"
    # Answer engine (orion docs/plans/answer-engine.md): one resident chat
    # model for every pipeline call, and Firecrawl for page extraction.
    ANSWER_MODEL      = "aether/qwen3.8-flash-next"
    FIRECRAWL_URL     = "http://${kubernetes_service_v1.firecrawl.metadata[0].name}.${local.firecrawl_ns}.svc.cluster.local:${local.firecrawl_api_port}"
    FIRECRAWL_API_KEY = var.secrets["firecrawl.api_key"]
    # Metrics + briefing drill-down → ClickHouse (ClickStack telemetry store;
    # agent_reader is the shared read-only identity for orion/Holmes/scripts).
    CLICKHOUSE_URL      = "https://clickhouse.home.shdr.ch"
    CLICKHOUSE_USER     = "agent_reader"
    CLICKHOUSE_PASSWORD = var.secrets["clickhouse.agent_reader_password"]
    # Still read by the deployed image's Home fetchers (alerts, quotas, platform
    # health) until they move to ClickHouse; drop once nothing reads it.
    PROMETHEUS_URL = "https://prometheus.home.shdr.ch"
    # Search "Ask Beryl" → the Hermes Beryl agent's OpenAI-compatible API
    # (in-cluster; key is the same random_password Hermes uses for its api_server).
    BERYL_API_URL = "http://hermes-beryl.hermes.svc.cluster.local:8642/v1"
    BERYL_API_KEY = random_password.hermes_api_server_key["beryl"].result
  }
}

resource "kubernetes_secret_v1" "orion_env" {
  depends_on = [module.namespace["orion"]]

  metadata {
    name      = "orion-env"
    namespace = local.orion_ns
  }

  data = local.orion_env

  type = "Opaque"
}

# The old SQLite volume. Nothing mounts it since the move to Postgres (no data
# was migrated: users log in again, caches start empty); kept until the
# Postgres deploy has run for a while, then delete it.
resource "kubernetes_persistent_volume_claim_v1" "orion_data" {
  depends_on = [module.namespace["orion"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "orion-data"
    namespace = local.orion_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "1Gi" } }
  }
}

# =============================================================================
# Postgres (CNPG)
# =============================================================================

resource "random_password" "orion_database_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "orion_cnpg_app" {
  depends_on = [module.namespace["orion"]]

  metadata {
    name      = "orion-cnpg-app"
    namespace = local.orion_ns
    labels    = local.orion_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.orion_database_user
    password = random_password.orion_database_password.result
  }
}

resource "kubectl_manifest" "orion_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.orion_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.orion_cnpg
      namespace = local.orion_ns
      labels    = merge(local.orion_labels, { "aether.sh/arm-ok" = "true" })
    }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      imageName            = "ghcr.io/cloudnative-pg/postgresql:16.14"
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
      storage = {
        size         = "5Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["orion"]
      bootstrap = {
        initdb = {
          database = local.orion_database
          owner    = local.orion_database_user
          secret   = { name = kubernetes_secret_v1.orion_cnpg_app.metadata[0].name }
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "orion" {
  depends_on = [
    kubectl_manifest.orion_cnpg_cluster,
    kubernetes_secret_v1.orion_gitlab_registry,
    kubernetes_secret_v1.orion_env,
  ]

  wait_for_rollout = false

  metadata {
    name      = "orion"
    namespace = local.orion_ns
    labels    = local.orion_labels
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    replicas = 1
    strategy { type = "RollingUpdate" }

    selector {
      match_labels = local.orion_labels
    }

    template {
      metadata {
        labels = local.orion_labels
        annotations = {
          # Roll the pod when the env secret changes — env_from alone does not
          # restart the container, and keel only reacts to image digests.
          "aether.shdr.ch/env-checksum" = nonsensitive(sha256(jsonencode(local.orion_env)))
        }
      }

      spec {
        enable_service_links = false

        image_pull_secrets {
          name = kubernetes_secret_v1.orion_gitlab_registry.metadata[0].name
        }

        container {
          name              = "orion"
          image             = local.orion_image
          image_pull_policy = "Always"

          env_from {
            secret_ref { name = kubernetes_secret_v1.orion_env.metadata[0].name }
          }

          port {
            container_port = local.orion_port
            name           = "http"
          }


          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/login"
              port = local.orion_port
            }
            initial_delay_seconds = 5
            period_seconds        = 15
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].spec[0].priority_class_name,
      # Keel force-updates rewrite these on a new :latest digest; tofu must not revert them.
      metadata[0].annotations["kubernetes.io/change-cause"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }
}

resource "kubernetes_service_v1" "orion" {
  depends_on = [kubernetes_deployment_v1.orion]

  metadata {
    name      = "orion"
    namespace = local.orion_ns
    labels    = local.orion_labels
  }

  spec {
    selector = local.orion_labels
    port {
      port        = local.orion_port
      target_port = local.orion_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "orion_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.orion]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "orion", namespace = local.orion_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.orion_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "orion", port = local.orion_port }]
      }]
    }
  }
}

# Declared egress for the answer engine's in-cluster flows (orion → litellm,
# searxng, firecrawl) plus ClickHouse via the home Caddy front (10.0.2.2:443,
# clickhouse.home.shdr.ch — same pattern as grafana.tf). Additive-only:
# enableDefaultDeny=false mirrors the cluster-baseline pattern — these rules
# pre-authorize the flows for the namespace-strategy default-deny flip
# without changing behavior today.
resource "kubernetes_manifest" "orion_answer_egress" {
  depends_on = [helm_release.cilium, module.namespace["orion"]]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "orion-answer-egress"
      namespace = local.orion_ns
    }
    spec = {
      endpointSelector = {}
      enableDefaultDeny = {
        ingress = false
        egress  = false
      }
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.litellm_ns
            }
          }]
          toPorts = [{
            ports = [{ port = tostring(local.litellm_port), protocol = "TCP" }]
          }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.searxng_ns
            }
          }]
          toPorts = [{
            ports = [{ port = tostring(local.searxng_port), protocol = "TCP" }]
          }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.firecrawl_ns
            }
          }]
          toPorts = [{
            ports = [{ port = tostring(local.firecrawl_api_port), protocol = "TCP" }]
          }]
        },
        {
          # ClickHouse HTTPS via the home Caddy front (10.0.2.2 → 10.0.2.3:8123).
          toCIDR = ["10.0.2.2/32"]
          toPorts = [{
            ports = [{ port = "443", protocol = "TCP" }]
          }]
        },
      ]
    }
  }
}

# `orion`: the personal agent behind Orion's threads (Home "Ask Orion", New
# chat). A declarative omp harness agent in org-personal with sessions, so a
# thread is a chain of Daimyo sessions and every message is a turn (Orion
# repo docs/mind-dump-2026-10-13.md §5, §8). Models through the sidecar's
# LiteLLM grant on moira/strong (Orion remaps per-function models through
# Moira aliases, not per turn); web research through Deskplane's MCP server,
# the same grant and network path as `researcher` (daimyo.tf); a per-user
# `personal` memory store, created on first use. 1 CPU: cold starts are
# ~4.5 s at 1 CPU vs ~7 s at 250m.
resource "kubectl_manifest" "daimyo_orion_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "orion"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "personal"
      description = "Shedrach's personal agent behind Orion threads."
      harness = {
        kind         = "omp"
        model        = "moira/strong"
        systemPrompt = <<-EOT
          You are Orion, Shedrach's personal agent. Answer directly and
          briefly, then act: you can run shell commands and edit files in
          your workspace, and research the web with search_web, scrape and
          parse_document. Prefer primary sources and cite the URLs you read.
          Keep what you learn about Shedrach's preferences in your personal
          memory and read it before answering.
        EOT
        tools        = { bash = true, files = true, web = false }
        maxTurns     = 200
      }
      resources  = { cpu = "1", memory = "2Gi", workspace = "2Gi" }
      operations = [{ name = "chat", deadline = "2h" }]
      grants = [
        { name = "models", model = { models = ["moira/strong"], budgetUsd = 5 } },
        {
          name = "web"
          mcp = {
            url = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            auth = {
              secret = {
                secret = { path = "orgs/personal/deskplane", key = "token" }
                header = { name = "Authorization" }
                prefix = "Bearer"
              }
            }
            tools = ["search_web", "scrape", "parse_document"]
          }
        },
      ]
      memory = [{
        store       = "personal"
        scope       = "perUser"
        access      = "write"
        description = "Shedrach's preferences, facts about his setup and decisions he has made."
      }]
      sessions  = { enabled = true, idleTtl = "4h", maxLifetime = "30d" }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}
