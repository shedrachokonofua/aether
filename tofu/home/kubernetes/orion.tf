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
  # Pinned to the main build by commit SHA; keel only follows digests of this
  # exact tag, so it stays put.
  orion_image            = "registry.gitlab.home.shdr.ch/so/orion/main:b1f48dfcee53f7519866d7b6e68bf3c758bef203"
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

# Pull secret for the private GitLab registry (same creds as open-design).
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
    # offline_access: the stored refresh token outlives the realm's 2h-idle /
    # 12h-max SSO session, so Daimyo calls keep working for the life of the
    # Orion session (30 days) instead of failing after two idle hours.
    OIDC_SCOPE         = "openid profile email offline_access"
    SESSION_SECRET     = random_password.orion_session_secret.result
    DATABASE_URL       = "postgresql://${local.orion_database_user}:${random_password.orion_database_password.result}@${local.orion_database_service}:5432/${local.orion_database}?sslmode=disable"
    # Threads → the `orion` Daimyo agent, as the signed-in user (keycloak.tf
    # orion client: token exchange to aud `daimyo`).
    DAIMYO_URL           = "https://daimyo.home.shdr.ch"
    TOKEN_ENCRYPTION_KEY = random_bytes.orion_token_encryption_key.base64
    # POST /auth/token: a `task login` token buys a 2 h session (automated QA).
    ORION_TOKEN_LOGIN = "1"
    # Notes vault: a git working tree on the orion-vault volume; Orion is the
    # only writer (Recreate deploys, one replica). The agent's notes grant
    # authenticates with this token (openbao_daimyo.tf, orgs/personal/orion-notes).
    VAULT_DIR = "/vault/notes"
    NOTES_MCP_TOKENS = jsonencode([{
      token = var.orion_notes_mcp_token
      name  = "Orion agent"
      email = "orion-agent@home.shdr.ch"
    }])
    # News widget → self-hosted Miniflux (API key minted in Miniflux, stored in SOPS).
    MINIFLUX_URL     = "https://miniflux.home.shdr.ch"
    MINIFLUX_API_KEY = var.secrets["miniflux.orion_api_key"]
    # LLM + web search → LiteLLM and SearXNG over cluster DNS (hairpin via the
    # LAN Caddy VM removed per namespace-strategy §8.2 / answer-engine Slice 13).
    LITELLM_URL     = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
    LITELLM_API_KEY = var.secrets["litellm.virtual_keys.orion"]
    SEARXNG_URL     = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.searxng_ns}.svc.cluster.local:${local.searxng_port}"
    # Answer engine (orion docs/plans/answer-engine.md): one resident chat
    # model for every pipeline call, and Deskplane for page extraction.
    ANSWER_MODEL        = "aether/qwen3.8-flash-next"
    DESKPLANE_URL       = "http://deskplane.deskplane.svc.cluster.local"
    DESKPLANE_API_TOKEN = random_password.deskplane_orion_token.result
    # Metrics + briefing drill-down → ClickHouse (ClickStack telemetry store;
    # agent_reader is the shared read-only identity for orion/Holmes/scripts).
    CLICKHOUSE_URL      = "https://clickhouse.home.shdr.ch"
    CLICKHOUSE_USER     = "agent_reader"
    CLICKHOUSE_PASSWORD = var.secrets["clickhouse.agent_reader_password"]
    # Still read by the deployed image's Home fetchers (alerts, quotas, platform
    # health) until they move to ClickHouse; drop once nothing reads it.
    PROMETHEUS_URL = "https://prometheus.home.shdr.ch"
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

# The notes vault's git working tree (VAULT_DIR). RWO: Orion is its single
# writer, so the deployment recreates instead of rolling.
resource "kubernetes_persistent_volume_claim_v1" "orion_vault" {
  depends_on = [module.namespace["orion"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "orion-vault"
    namespace = local.orion_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }

  lifecycle {
    prevent_destroy = true
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
    kubernetes_persistent_volume_claim_v1.orion_vault,
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
    # Recreate: the notes vault (RWO volume, a lock file under VAULT_DIR)
    # allows one writer, so the old pod stops before the new one starts.
    strategy { type = "Recreate" }

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

          volume_mount {
            name       = "vault"
            mount_path = "/vault"
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

        volume {
          name = "vault"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.orion_vault.metadata[0].name
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
# searxng, deskplane) plus ClickHouse via the home Caddy front (10.0.2.2:443,
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
              "io.kubernetes.pod.namespace" = local.deskplane_namespace
            }
          }]
          toPorts = [{
            # Cilium matches the post-DNAT backend port (deskplane-serve :8080),
            # not the Service port 80 that DESKPLANE_URL dials.
            ports = [{ port = "8080", protocol = "TCP" }]
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
        kind  = "omp"
        model = "moira/strong"
        systemPrompt = join("\n\n", [
          trimspace(<<-EOT
            You are Orion, Shedrach's personal agent. Answer directly and
            briefly, then act: you can run shell commands and edit files in
            your workspace, and research the web with search_web, scrape and
            parse_document. Prefer primary sources and cite the URLs you read.
            Keep what you learn about Shedrach's preferences in your personal
            memory and read it before answering.

            Your workspace has no direct internet access: fetching a URL with
            read, curl or similar hangs until it times out. Reach the web only
            through search_web, scrape and parse_document. To show an image,
            put its URL in an orion-images block; Orion fetches it for
            Shedrach, so you don't need to download it.

            Shedrach's notes vault (Markdown, Obsidian-compatible) is yours
            through the notes tools: search and read before writing, keep his
            structure, and give every change a short reason. Your changes
            apply at once and he can revert them.

            You can drive a desktop through open_session and the computer-use
            tools; Shedrach watches it in the thread's Screen tab. Only
            kind "desktop" (an Ubuntu desktop with a browser) has a screen:
            use it whenever he wants to watch, take over, or follow along,
            and for interactive browsing. kind "browser" is headless, cannot
            be watched, and suits quick unattended page work. Follow the
            Deskplane section of the formats below.

            Files Shedrach attaches are copied into /workspace/inputs/; his
            message lists each one as "Attached: inputs/<name>". Open them
            from there.
          EOT
          ),
          # The rich reply contract Orion renders (orion docs/agent-response-formats.md).
          file("${path.module}/orion-agent-formats.md"),
        ])
        tools    = { bash = true, files = true, web = false }
        maxTurns = 200
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
            tools = [
              "search_web", "scrape", "parse_document",
              # Computer use: Shedrach watches or takes over in the Screen tab.
              "open_session", "list_sessions", "close_session", "watch_link", "screenshot",
              "navigate", "click", "double_click", "move", "drag", "type_text", "key", "scroll", "wait",
              "run_browser_task", "start_desktop_task",
            ]
          }
        },
        {
          name = "notes"
          mcp = {
            # Orion's notes MCP, in-cluster (daimyo.tf opens personal-tasks → orion:3000).
            url = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/notes"
            auth = {
              secret = {
                secret = { path = "orgs/personal/orion-notes", key = "token" }
                header = { name = "Authorization" }
                prefix = "Bearer"
              }
            }
            tools = [
              "notes_search", "notes_get", "notes_create", "notes_patch_block",
              "notes_set_property", "notes_move", "notes_delete",
            ]
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
