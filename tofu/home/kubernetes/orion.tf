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
  orion_image            = "registry.gitlab.home.shdr.ch/so/orion/main:2dba08abc2cac02819dc05f744dfdf77760f6846"
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

# The Trace view (orion docs/trace-view-research.md) reads LiteLLM spend rows
# by request id. Its key reaches only GET /spend/logs and no models; it is
# registered with the master key on apply, like daimyo_buckets.
resource "random_password" "orion_litellm_spend" {
  length  = 48
  special = false
}

resource "terraform_data" "orion_litellm_spend_key" {
  triggers_replace = [sha256(random_password.orion_litellm_spend.result)]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      if curl -fsS -H "Authorization: Bearer $MASTER" "$LITELLM/key/info?key=$KEY" >/dev/null 2>&1; then exit 0; fi
      curl -fsS -H "Authorization: Bearer $MASTER" -H 'content-type: application/json' \
        -d "{\"key\":\"$KEY\",\"key_alias\":\"orion-trace\",\"allowed_routes\":[\"/spend/logs\"],\"models\":[\"no-default-models\"],\"metadata\":{\"owner\":\"orion\",\"purpose\":\"Trace view spend lookup\"}}" \
        "$LITELLM/key/generate" >/dev/null
    EOT
    environment = {
      LITELLM = "https://${local.litellm_host}"
      MASTER  = var.secrets["litellm.master_key"]
      KEY     = "sk-${random_password.orion_litellm_spend.result}"
    }
  }
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
    OIDC_SCOPE     = "openid profile email offline_access"
    SESSION_SECRET = random_password.orion_session_secret.result
    DATABASE_URL   = "postgresql://${local.orion_database_user}:${random_password.orion_database_password.result}@${local.orion_database_service}:5432/${local.orion_database}?sslmode=disable"
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
    NOTES_MCP_TOKENS = jsonencode([
      {
        token = var.orion_notes_mcp_token
        name  = "Orion agent"
        email = "orion-agent@home.shdr.ch"
      },
      {
        # The notes-keeper agent: keeperId confines its writes to keep:-marked
        # sections and attributes its runs in Activity.
        token    = var.orion_keeper_notes_mcp_token
        name     = "Notes keeper"
        email    = "notes-keeper@home.shdr.ch"
        keeperId = "notes-keeper"
      },
    ])
    # Who may bulk-import into the vault (POST /api/notes/import).
    NOTES_IMPORT_ADMINS = "shedrachokonofua@gmail.com"
    # Feed agent → Orion's home MCP (/api/mcp/home); the orion-feed agent's
    # home grant reads the same token from OpenBao orgs/personal/orion-home.
    HOME_MCP_TOKENS = jsonencode([{
      token = var.orion_home_mcp_token
      name  = "Orion feed agent"
      email = "orion-feed@home.shdr.ch"
    }])
    # Feed: Daimyo agents the poller ingests (legacy name kept; the poller
    # also polls every orion-feed-<topic> agent), the single feed owner (OIDC
    # subject), and ntfy for needsYou cards (topic is a random secret,
    # openbao_daimyo.tf orgs/personal/orion-ntfy; ntfy has no auth).
    FEED_AGENT = "personal/orion-feed"
    FEED_OWNER = var.operator_oidc_subject
    NTFY_URL   = "https://ntfy.home.shdr.ch"
    NTFY_TOPIC = var.orion_ntfy_topic
    # GitLab for the gitlab feed topic's home-MCP `gitlab` tool: a read_api
    # token of the `orion-feed` GitLab user (reporter on so, seven30, lute and
    # shdrch's projects; expires 2027-10-15).
    GITLAB_URL   = "https://gitlab.home.shdr.ch"
    GITLAB_TOKEN = var.secrets["gitlab.orion_feed_token"]
    # Whose reviews and assignments count as "needs Shedrach" (the token is
    # the bot's, so GitLab's `me` would be the bot).
    GITLAB_REVIEWER = "shdrch"
    # News widget → self-hosted Miniflux (API key minted in Miniflux, stored in SOPS).
    MINIFLUX_URL     = "https://miniflux.home.shdr.ch"
    MINIFLUX_API_KEY = var.secrets["miniflux.orion_api_key"]
    # LLM + web search → LiteLLM and SearXNG over cluster DNS (hairpin via the
    # LAN Caddy VM removed per namespace-strategy §8.2 / answer-engine Slice 13).
    LITELLM_URL     = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
    LITELLM_API_KEY = var.secrets["litellm.virtual_keys.orion"]
    # Trace view: spend rows by request id (orion_litellm_spend_key above).
    LITELLM_SPEND_KEY = "sk-${random_password.orion_litellm_spend.result}"
    SEARXNG_URL       = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.searxng_ns}.svc.cluster.local:${local.searxng_port}"
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
    kubernetes_secret_v1.orion_gitlab_registry,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.orion_cnpg
      namespace = local.orion_ns
      # No aether.sh/arm-ok: the image below is amd64-only, so Kyverno keeps the
      # instance off the ARM pool.
      labels = local.orion_labels
    }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      # Postgres 18 with pg_textsearch (BM25) and pgvector, built from Orion's
      # ops/postgres/Dockerfile on the 18.6 standard trixie image. Reached from 16.14
      # (bullseye) via 16.15-standard-trixie, because CNPG's in-place pg_upgrade
      # needs both images on the same OS. Collation is C, so no reindex.
      imageName        = "registry.gitlab.home.shdr.ch/so/orion/postgres:18.6-pgts1.5.1"
      imagePullSecrets = [{ name = kubernetes_secret_v1.orion_gitlab_registry.metadata[0].name }]
      postgresql = {
        # pg_textsearch must be preloaded (its README); vector needs nothing here.
        shared_preload_libraries = ["pg_textsearch"]
      }
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

# Extensions in Orion's database, managed by CNPG. The database itself comes from
# the cluster's initdb; databaseReclaimPolicy keeps it if this resource goes away.
resource "kubectl_manifest" "orion_cnpg_database" {
  depends_on = [kubectl_manifest.orion_cnpg_cluster]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Database"
    metadata = {
      name      = "orion-db"
      namespace = local.orion_ns
      labels    = local.orion_labels
    }
    spec = {
      name                  = local.orion_database
      owner                 = local.orion_database_user
      cluster               = { name = local.orion_cnpg }
      databaseReclaimPolicy = "retain"
      extensions = [
        { name = "pg_textsearch", ensure = "present" },
        { name = "vector", ensure = "present" },
      ]
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

locals {
  # The `orion` agent reaches LiteLLM's MCP gateway through its per-server
  # routes (/mcp/<server>): one grant per server, so each keeps its own tool
  # policy. The sidecar adds the agent's key (openbao_daimyo.tf
  # daimyo_orion_litellm_mcp); the gateway already reaches every server.
  orion_gateway_mcp = "${local.daimyo_litellm_upstream}/mcp"
  orion_gateway_auth = {
    secret = {
      secret = { path = "orgs/personal/litellm-mcp", key = "token" }
      header = { name = "x-litellm-api-key" }
      prefix = "Bearer"
    }
  }
  # Policy for tools that should ask Shedrach first (deleting, spending,
  # publishing, admin). The sidecar parks the call on a Daimyo tool approval
  # and Orion renders it in the thread. Session pods park under their session
  # id, which Daimyo resolves to the running turn (daimyo 89e1a1c; before it
  # every `ask` from a session answered 404 and this was "deny").
  orion_ask = "ask"
}

# `orion`: the personal agent behind Orion's threads (Home "Ask Orion", New
# chat). A declarative omp harness agent in org-personal with sessions, so a
# thread is a chain of Daimyo sessions and every message is a turn (Orion
# repo docs/mind-dump-2026-10-13.md §5, §8). Models through the sidecar's
# LiteLLM grant on moira/strong (Orion remaps per-function models through
# Moira aliases, not per turn); web research through Deskplane's MCP server,
# the same grant and network path as `researcher` (daimyo.tf); a per-user
# `personal` memory store, created on first use. 2 CPU limit: the harness CLI's
# start is CPU-bound (a pod used ~12.7 CPU-seconds in its first ~15 s and hit
# the 1 CPU limit in 15% of intervals; ~4.5 s at 1 CPU vs ~7 s at 250m before
# that). Requests sit far below the limits because a session pod idles most of
# its life (7 days, 23 pods: median 0.06 CPU / 512 MiB, p90 peak 0.84 CPU /
# 773 MiB), so idle threads stay cheap to keep warm.
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
            through search_web, scrape and parse_document.

            Show, don't just tell. Orion renders rich blocks on his phone and
            desktop, so use them liberally wherever they make an answer
            clearer or more vivid: orion-images for the places, products,
            people and things you talk about; orion-chart, orion-table and
            orion-stat for numbers, prices, comparisons and timelines;
            orion-map for locations and routes; orion-card for options;
            orion-video for a YouTube video whenever one helps (how-tos,
            reviews, trailers, music, places, talks); mermaid diagrams for
            anything with structure, flow, relationships or time (pick the
            type that fits from the full range, use his real hosts, services,
            people and dates, keep it focused); and a2ui panels when he
            should choose, compare, approve or fill in details. A strong reply
            often leads with a visual and a few sentences. Get real image URLs
            (scrape a relevant page with formats ["images"], or use its
            metadata image); Orion fetches and resizes them, so never download
            them and never invent a URL. Find videos with search_web (add
            site:youtube.com) and use a URL from the results; never guess a
            video id. Skip visuals that add nothing. When the moment is
            playful or a win, or he says lol or asks, you may react with one
            GIF: find a real one with search_web (site:giphy.com) and put its
            link alone on its own line; never in serious, technical or
            bad-news replies.

            Shedrach's notes vault (Markdown, Obsidian-compatible) is yours
            through the notes tools: search and read before writing, keep his
            structure, and give every change a short reason. Your changes
            apply at once and he can revert them.

            Search Shedrach's other threads with `threads_search` when he refers to earlier work or a related conversation would help; read one with `thread_read`.

            Browse through the web engine first: scrape (engine_name "auto"
            escalates fetch, headless, then a real headful browser when a
            site blocks automation), and for pages you must click or fill,
            scrape with keep_open=true and drive the page with interact_prompt,
            interact_script, interact_snapshot and interact_screenshot; call
            close_interact when done. Use start_crawl, start_batch_scrape or
            start_extract with get_job for many pages.

            Open a Deskplane session (open_session plus the computer-use
            tools) only when Shedrach wants to watch or take over, or the task
            needs a whole desktop. kind "desktop" has a screen he can see in
            the thread's Screen tab but takes a minute or more to start; kind
            "browser" is headless and invisible unless you pass watch=true,
            which opens a visible Chrome in seconds. Follow the Deskplane
            section of the formats below.

            When a web tool returns status "needs_human", a site needs
            Shedrach to solve a challenge: tell him in one line (his Screen
            tab shows the page), then call handoff(id, "wait") until he is
            done; use "resume" when he says it is solved and "skip" if he
            declines.

            Shedrach's other services are tools too: his music library and
            Spotify (siren), media (jellyfin, tmdb), sports (espn), markets
            (finviz), maps and places (google_maps), image generation
            (comfyui), his AFFiNE workspace (affine), his message archive
            (mnemo: email and chats, read-only), travel search (flights,
            kiwi, skiplagged, trivago, ferryhopper), his Football Manager save
            (fm), pop sites (pop), Colony (colony) and Daimyo (daimyo). Use
            them whenever they answer better than the web. Deleting, spending,
            publishing and admin calls wait for his approval in the thread;
            make them only when he asked for that outcome, and when one is
            refused, say so in a line and carry on without it.

            Files Shedrach attaches are copied into /workspace/inputs/; his
            message lists each one as "Attached: inputs/<name>". Open them
            from there. A reply to a Home feed post attaches inputs/post.md
            (the post), inputs/brief.md (that agent's brief) and
            inputs/recent.md (its recent posts). When he says how that agent
            should behave from now on, add it under `## Your edits` in
            Feed/Preferences/<topic>.md with the notes tools and confirm in
            one line. A question about the post does not change the brief.
          EOT
          ),
          # The rich reply contract Orion renders (orion docs/agent-response-formats.md).
          file("${path.module}/orion-agent-formats.md"),
        ])
        tools    = { bash = true, files = true, web = false }
        maxTurns = 200
      }
      resources = {
        cpu       = "2"
        memory    = "2Gi"
        workspace = "2Gi"
        requests  = { cpu = "100m", memory = "768Mi" }
      }
      operations = [{ name = "chat", deadline = "2h" }]
      grants = concat([
        { name = "models", model = { models = ["moira/strong"], budgetUsd = 5 } },
        {
          name = "web"
          mcp = {
            url = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            # The task's own token (aud=deskplane): sessions it opens are owned by
            # agent:personal/personal/orion on behalf of the thread's user.
            auth = { taskToken = { audience = "deskplane" } }
            tools = [
              "search_web", "scrape", "parse_document", "map_site",
              # Web engine jobs and kept-open pages (scrape keep_open=True); its
              # engine_name="auto" escalates fetch -> headless -> headful.
              "start_crawl", "start_batch_scrape", "start_extract", "get_job", "cancel_job",
              # Human handoff: wait on, resume or skip a needs_human page.
              "handoff",
              "interact_prompt", "interact_script", "interact_screenshot", "interact_snapshot",
              "close_interact", "save_profile", "list_profiles",
              # Computer use: Shedrach watches or takes over in the Screen tab.
              "open_session", "list_sessions", "close_session", "watch_link", "screenshot",
              "navigate", "click", "double_click", "move", "drag", "type_text", "key", "scroll", "wait",
              "run_browser_task", "start_desktop_task",
            ]
          }
        },
        {
          name = "threads"
          mcp = {
            # Orion's threads MCP, in-cluster (same path as the notes grant).
            url = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/threads"
            # A Daimyo task token (aud orion-threads): Orion verifies it against
            # the org issuer and reads the calling session from its `task` claim.
            auth = { taskToken = { audience = "orion-threads" } }
            tools = [
              "threads_search", "thread_read",
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
              "notes_set_property", "notes_move", "notes_delete", "notes_query",
              # Note sqlite sidecars and declared data sources (_sources/*.yaml).
              "note_db_exec", "note_db_query", "source_list", "source_query",
            ]
          }
        },
        # Shedrach's other services. Reads and reversible actions in his own
        # tools are allowed; deleting, spending, publishing and admin use
        # local.orion_ask. Tools a task must never have are left out, which
        # hides them (daimyo: approval_resolve would let the agent approve its
        # own held calls; agent, project and workflow writes are config).
        # Names are exact: Daimyo's grant allowlist does not match globs.
        {
          name = "pop"
          mcp = {
            url  = "https://pop.home.shdr.ch/mcp/aether"
            auth = { taskToken = { audience = "pop" } }
            tools = [
              "projects_list", "deploys_list", "deploy_get", "aliases_list",
              "events_list", "forms_list", "hooks_list", "telemetry_link",
              "deploy_begin", "deploy_files", "deploy_finalize",
              { name = "project_create", policy = local.orion_ask },
              { name = "project_delete", policy = local.orion_ask },
              { name = "alias_set", policy = local.orion_ask },
              { name = "alias_rollback", policy = local.orion_ask },
              { name = "alias_delete", policy = local.orion_ask },
              { name = "hook_add", policy = local.orion_ask },
              { name = "hook_remove", policy = local.orion_ask },
              { name = "forms_export", policy = local.orion_ask },
              { name = "form_file_link", policy = local.orion_ask },
            ]
          }
        },
        {
          name = "daimyo"
          mcp = {
            # In-cluster API (daimyo_tasks_egress allows it; the public host is
            # not on the egress list). Task tokens never get config writes.
            url  = "http://${local.daimyo_svc_name}.daimyo-system.svc.cluster.local/mcp?org=personal"
            auth = { taskToken = { audience = "daimyo" } }
            tools = [
              "agents_list", "agent_get", "task_get", "task_events_tail",
              "sessions_list", "session_events_tail", "workflow_run_get",
              "approvals_list", "schedules_list", "files_list", "files_get",
              "memory_list_stores", "memory_list", "memory_read", "memory_versions",
              "memory_search",
              { name = "task_create", policy = local.orion_ask },
              { name = "task_cancel", policy = local.orion_ask },
              { name = "session_create", policy = local.orion_ask },
              { name = "session_send", policy = local.orion_ask },
              { name = "session_close", policy = local.orion_ask },
              { name = "session_warm", policy = local.orion_ask },
              { name = "session_rewind", policy = local.orion_ask },
              { name = "session_fork", policy = local.orion_ask },
              { name = "workflow_start", policy = local.orion_ask },
              { name = "workflow_run_script", policy = local.orion_ask },
              { name = "sandbox_create", policy = local.orion_ask },
              { name = "sandbox_exec", policy = local.orion_ask },
              { name = "sandbox_read_file", policy = local.orion_ask },
              { name = "sandbox_write_file", policy = local.orion_ask },
              { name = "sandbox_delete", policy = local.orion_ask },
              { name = "files_upload", policy = local.orion_ask },
              { name = "memory_write", policy = local.orion_ask },
              { name = "memory_delete", policy = local.orion_ask },
              { name = "memory_restore", policy = local.orion_ask },
              { name = "memory_dream", policy = local.orion_ask },
              { name = "memory_dream_resolve", policy = local.orion_ask },
              { name = "attestation_revoke", policy = local.orion_ask },
            ]
          }
        },
        ], [
        # The LiteLLM gateway's servers, one grant each (orion_agent_tools.tf).
        for server, tools in local.orion_gateway_tools : {
          name = server
          mcp = {
            url  = "${local.orion_gateway_mcp}/${server}"
            auth = local.orion_gateway_auth
            tools = concat(
              tools.allow,
              [for tool in tools.ask : { name = tool, policy = local.orion_ask }],
            )
          }
        }
        ], [
        {
          name = "mnemo"
          mcp = {
            # His message archive, read-only and without auth. Its public host:
            # in-cluster requests get a 307 to it, which the sidecar refuses.
            # orion_agent_egress below resolves it for orion's pods only.
            url = "https://mnemo.home.shdr.ch/mcp"
            tools = [
              "mnemo.search_messages", "mnemo.rag_context", "mnemo.get_thread", "mnemo.timeline",
              "mnemo.get_message", "mnemo.source_status",
            ]
          }
        },
        # Keyless travel search, the same servers as trip-planner
        # (trip_planner.tf; daimyo_tasks_egress opens them for personal).
        {
          name = "flights"
          mcp = {
            url   = local.fli_url
            tools = ["search_flights", "search_dates", "get_booking_options", "find_airports"]
          }
        },
        {
          name = "kiwi"
          mcp  = { url = "https://mcp.kiwi.com", tools = ["search-flight"] }
        },
        {
          name = "skiplagged"
          mcp = {
            url = "https://mcp.skiplagged.com/mcp"
            tools = [
              "sk_flights_search", "sk_flex_departure_calendar", "sk_flex_return_calendar",
              "sk_destinations_anywhere", "sk_resolve_iata",
              "sk_hotels_search", "sk_hotel_details", "sk_cars_search",
            ]
          }
        },
        {
          name = "trivago"
          mcp = {
            url = "https://mcp.trivago.com/mcp"
            tools = [
              "trivago-accommodation-search", "trivago-accommodation-radius-search",
              "trivago-destination-price-trends",
            ]
          }
        },
        {
          name = "ferryhopper"
          mcp = {
            url = "https://mcp.ferryhopper.com/mcp"
            tools = [
              "search_ferry_trips", "trip_details", "get_ports",
              "get_direct_connections_for_ports", "get_disruptions",
            ]
          }
        },
      ])
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

# Projects (orion docs/projects-design.md): one long-lived coordinator session
# per project. It holds no shell, files or web tools — it answers small
# questions itself and spawns briefed worker threads on the `orion` agent
# through Orion's threads MCP (identity comes from the Daimyo session header;
# project tools are refused for non-coordinator callers server-side).
resource "kubectl_manifest" "daimyo_coordinator_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "coordinator"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "personal"
      description = "Coordinates one of Shedrach's Orion projects: spawns, briefs and tracks worker threads."
      harness = {
        kind  = "omp"
        model = "moira/flash"
        systemPrompt = trimspace(<<-EOT
          You coordinate one of Shedrach's projects in Orion. Call project_get at the start of a session and follow the project's instructions.
          Answer small questions yourself. For real work, call thread_start with a short title and a self-contained brief: the thread's agent sees only the brief and the project's goal and instructions. Split independent work into parallel threads; at most 4 run at once.
          Messages that start with "[orion] Thread updates:" come from Orion, not Shedrach. For each update, read the thread with thread_read when you need its result, then tell Shedrach in one or two lines what is done and what waits on him, naming the thread. Do not redo a thread's work yourself; use thread_message to steer it and thread_stop to stop it.
          Use threads_search to find earlier work in his other threads.
          Keep replies short.
        EOT
        )
        # files: omp invokes MCP tools by writing to xd://mcp__<tool> devices.
        tools    = { bash = false, files = true, web = false }
        maxTurns = 60
      }
      resources = {
        cpu       = "2"
        memory    = "2Gi"
        workspace = "2Gi"
        requests  = { cpu = "100m", memory = "768Mi" }
      }
      operations = [{ name = "chat", deadline = "30m" }]
      grants = [
        { name = "models", model = { models = ["moira/flash"], budgetUsd = 1 } },
        {
          name = "threads"
          mcp = {
            url = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/threads"
            auth = { taskToken = { audience = "orion-threads" } }
            tools = [
              "threads_search", "thread_read", "project_get", "threads_list",
              "thread_start", "thread_message", "thread_stop",
            ]
          }
        },
        {
          name = "notes"
          mcp = {
            url = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/notes"
            auth = {
              secret = {
                secret = { path = "orgs/personal/orion-notes", key = "token" }
                header = { name = "Authorization" }
                prefix = "Bearer"
              }
            }
            tools = [
              "notes_search", "notes_get",
            ]
          }
        },
      ]
      sessions  = { enabled = true, idleTtl = "24h", maxLifetime = "30d" }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

# Notes v2 (orion docs/plans/notes-full.md N9/N10): one notes-keeper agent on
# a static hourly schedule refreshes kept-current sections and evaluates
# watches. Orion never creates schedules; notes_due decides whether any
# section is actually due, and the server refuses a keeper write outside a
# keep:-marked section (its token's keeperId).
resource "kubectl_manifest" "daimyo_notes_keeper_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "notes-keeper"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "personal"
      description = "Refreshes kept-current Notes sections and evaluates watches, hourly."
      harness = {
        kind  = "omp"
        model = "moira/strong"
        systemPrompt = trimspace(<<-EOT
          You are the notes keeper for Shedrach's Markdown vault. Each run:
          1. Call notes_due. It returns only the kept sections whose cadence
             has elapsed, with the note path, heading, instructions and cadence.
          2. For each entry, call notes_get for its path, follow its
             instructions using sources you can verify (source_list and
             source_query for his declared data sources; search_web, scrape and
             parse_document for the web), and call notes_patch_block with
             exactly that path and block. The content replaces the whole
             section, so begin with its heading line. Edit nothing outside that
             section; the server rejects it.
          3. Then call notes_watches_run once to append newly matching watch
             changes, and report what you changed and what it appended.
          If a section cannot be refreshed from verifiable information, leave
          it unchanged and say why in one line. Never create, move, rename or
          delete notes, and never edit frontmatter.
        EOT
        )
        tools    = { bash = false, files = true, web = false }
        maxTurns = 60
      }
      resources = { cpu = "500m", memory = "1Gi", workspace = "512Mi" }
      operations = [{
        name           = "keep"
        deadline       = "10m"
        promptTemplate = "'Refresh every due kept-current section, then evaluate watches.'"
      }]
      schedules = [{
        name      = "keep"
        cron      = "0 * * * *"
        timezone  = "America/Toronto"
        operation = "keep"
        overlap   = "skip"
        jitter    = "300s"
      }]
      grants = [
        { name = "models", model = { models = ["moira/strong"], budgetUsd = 1 } },
        {
          name = "notes"
          mcp = {
            url = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/notes"
            auth = {
              secret = {
                secret = { path = "orgs/personal/orion-keeper-notes", key = "token" }
                header = { name = "Authorization" }
                prefix = "Bearer"
              }
            }
            tools = [
              "notes_due", "notes_get", "notes_patch_block", "notes_watches_run",
              "source_list", "source_query",
            ]
          }
        },
        {
          name = "web"
          mcp = {
            url   = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            auth  = { taskToken = { audience = "deskplane" } }
            tools = ["search_web", "scrape", "parse_document"]
          }
        },
      ]
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

# Mnemo for the `orion` agent's mnemo grant only: its MCP has no auth, so the
# name is the boundary. orion's task pods may resolve and reach
# mnemo.home.shdr.ch (the gateway, which mnemo-ingress admits); other personal
# agents (orion-feed-*, researcher, trip-planner) cannot resolve it. Additive
# to daimyo_tasks_egress (daimyo.tf), which keeps default-deny and the rest of
# the DNS allowlist.
resource "kubernetes_manifest" "orion_agent_egress" {
  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "orion-agent-egress"
      namespace = "personal-tasks"
      labels    = local.daimyo_labels
    }
    spec = {
      endpointSelector = { matchLabels = { "daimyo.shdr.ch/agent" = "orion" } }
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "k8s-app"                     = "kube-dns"
              "io.kubernetes.pod.namespace" = "kube-system"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
            rules = { dns = [{ matchName = "mnemo.home.shdr.ch" }] }
          }]
        },
        {
          toFQDNs = [{ matchName = "mnemo.home.shdr.ch" }]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
