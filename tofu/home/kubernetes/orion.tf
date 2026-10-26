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
  orion_chart_values     = jsondecode(file("${path.module}/orion_chart_values.json"))
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
    # Tables' read-only SQL (Orion src/lib/server/tables/query.ts): a separate
    # login that can only select from the generated views in schema `tables`.
    TABLES_READER_DATABASE_URL = "postgresql://orion_tables_reader:${random_password.orion_tables_reader_password.result}@${local.orion_database_service}:5432/${local.orion_database}?sslmode=disable"
    # Threads → the `orion` Daimyo agent, as the signed-in user (keycloak.tf
    # orion client: token exchange to aud `daimyo`).
    DAIMYO_URL           = "https://daimyo.home.shdr.ch"
    TOKEN_ENCRYPTION_KEY = random_bytes.orion_token_encryption_key.base64
    # POST /auth/token: a `task login` token buys a 2 h session (automated QA).
    ORION_TOKEN_LOGIN = "1"
    # Notes vault: a git working tree on the orion-vault volume; Orion is the
    # only writer (Recreate deploys, one replica). Agents reach the notes and
    # home MCPs with Daimyo task tokens (audiences orion-notes, orion-home).
    VAULT_DIR = "/vault/notes"
    # Who may bulk-import into the vault (POST /api/notes/import).
    NOTES_IMPORT_ADMINS = "shedrachokonofua@gmail.com"
    # Feed: the single feed owner (OIDC subject) whose registry feed topics
    # Orion imports, and ntfy for needsYou cards (topic is a random secret,
    # openbao_daimyo.tf orgs/personal/orion-ntfy; ntfy has no auth).
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

# Read-only login for Tables SQL. CNPG manages the role (spec.managed.roles);
# Orion's migrations grant it usage on schema `tables` and select on its views.
resource "random_password" "orion_tables_reader_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "orion_tables_reader" {
  depends_on = [module.namespace["orion"]]

  metadata {
    name      = "orion-tables-reader"
    namespace = local.orion_ns
    labels    = merge(local.orion_labels, { "cnpg.io/reload" = "true" })
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = "orion_tables_reader"
    password = random_password.orion_tables_reader_password.result
  }
}

resource "kubectl_manifest" "orion_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.orion_cnpg_app,
    kubernetes_secret_v1.orion_tables_reader,
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
      managed = {
        roles = [{
          name            = "orion_tables_reader"
          ensure          = "present"
          login           = true
          connectionLimit = 10
          passwordSecret  = { name = kubernetes_secret_v1.orion_tables_reader.metadata[0].name }
        }]
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

removed {
  from = kubernetes_deployment_v1.orion
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_service_v1.orion
  lifecycle { destroy = false }
}

resource "helm_release" "orion" {
  name                = "orion"
  namespace           = local.orion_ns
  repository          = "oci://registry.gitlab.home.shdr.ch/so/orion/charts"
  chart               = "orion"
  version             = "0.1.0-g${local.orion_release}"
  repository_username = local.orion_registry_user
  repository_password = local.orion_registry_pass
  wait                = true
  timeout             = 900
  atomic              = false
  cleanup_on_fail     = false

  values = [yamlencode(merge(local.orion_chart_values, {
    image       = { repository = "registry.gitlab.home.shdr.ch/so/orion/main", tag = local.orion_release }
    envChecksum = nonsensitive(sha256(jsonencode(local.orion_env)))
  }))]

  depends_on = [
    helm_release.daimyo,
    kubectl_manifest.daimyo_project,
    kubectl_manifest.orion_cnpg_cluster,
    kubernetes_secret_v1.orion_gitlab_registry,
    kubernetes_secret_v1.orion_env,
    kubernetes_persistent_volume_claim_v1.orion_vault,
  ]
}

resource "kubernetes_manifest" "orion_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.orion]

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
  # Dev retains read-only ClickStack access through the existing Orion gateway
  # key (openbao_daimyo.tf daimyo_orion_litellm_mcp), held by the sidecar.
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

removed {
  from = kubectl_manifest.daimyo_orion_agent
  lifecycle { destroy = false }
}

resource "kubectl_manifest" "daimyo_dev_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "dev"
      namespace = "org-personal"
      labels    = merge(local.daimyo_cr_labels, { "orion.shdr.ch/thread" = "chat" })
    }
    spec = {
      project     = "personal"
      description = "Software engineer for Shedrach's GitLab repositories (groups so and seven30): investigates code and the home Kubernetes cluster (read-only), makes changes on a branch and opens merge requests."
      harness = {
        kind  = "omp"
        image = local.daimyo_harness_omp_dev_image
        model = "moira/strong"
        systemPrompt = trimspace(<<-EOT
          You are Shedrach's software engineer in Orion. You work in /workspace on his GitLab repositories (groups so and seven30) through git at $DAIMYO_GIT_BASE_URL (for example `git clone $DAIMYO_GIT_BASE_URL/so/orion.git`); you push as your own GitLab user.
          Work on a branch named for the change, never on main, and open a merge request with `git push -o merge_request.create -o merge_request.title="…" origin HEAD:<branch>`. Never merge. Report the MR URL.
          Read before you write: find the repo's conventions (AGENTS.md, README, Taskfile, package.json, Cargo.toml) and follow them. Run the repo's own formatter, linter and tests before pushing when the toolchain is available (node, bun, python3, cargo); say which checks you ran and which you could not.
          You can read the home Kubernetes cluster with kubectl (read-only: no Secrets, no exec, no changes). Use it to inspect deployments, logs and events when a change touches running services. For logs, traces and metrics use the clickstack tools (clickstack_sql runs read-only ClickHouse SQL on the `otel` database).
          Use threads_search and thread_read to find earlier conversations about the work. Use search_web and scrape for documentation. Use the pop tools to deploy and inspect pop sites (deploy_begin → deploy_files → deploy_finalize); alias, hook, project and form-export changes wait for his approval.
          Keep replies short: what you changed, where, how you verified it, and anything he must decide.
        EOT
        )
        tools    = { bash = true, files = true, web = false }
        maxTurns = 300
      }
      resources = {
        cpu       = "4"
        memory    = "8Gi"
        workspace = "20Gi"
        requests  = { cpu = "100m", memory = "768Mi" }
      }
      operations = [{ name = "chat", deadline = "2h" }]
      grants = [
        { name = "models", model = { models = ["moira/strong"], budgetUsd = 10 } },
        { name = "git-so", git = { repo = "so/*", access = "write" } },
        { name = "git-seven30", git = { repo = "seven30/*", access = "write" } },
        { name = "kubernetes", kubernetes = { serviceAccount = "dev" } },
        {
          name = "web"
          mcp = {
            url   = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            auth  = { taskToken = { audience = "deskplane" } }
            tools = ["search_web", "scrape", "parse_document"]
          }
        },
        {
          name = "threads"
          mcp = {
            url   = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/threads"
            auth  = { taskToken = { audience = "orion-threads" } }
            tools = ["threads_search", "thread_read"]
          }
        },
        {
          # Same pop grant and policy as `orion`: deploys free, admin asks.
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
          # Homelab logs/traces/metrics (ClickHouse via HyperDX's MCP), read-only.
          # Reuses orion's gateway key: the grant allowlist limits dev to
          # clickstack, and the key never leaves the sidecar.
          name = "clickstack"
          mcp = {
            url   = "${local.orion_gateway_mcp}/clickstack"
            auth  = local.orion_gateway_auth
            tools = local.orion_gateway_tools.clickstack.allow
          }
        },
      ]
      sessions  = { enabled = true, idleTtl = "24h", maxLifetime = "30d" }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

resource "kubectl_manifest" "daimyo_local_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "local"
      namespace = "org-personal"
      labels    = merge(local.daimyo_cr_labels, { "orion.shdr.ch/thread" = "chat" })
    }
    spec = {
      project     = "personal"
      description = "Private assistant that runs entirely on the home GPU (Qwen 3.8 Flash Next): nothing leaves the house. Slower and less capable than the cloud agents."
      harness = {
        kind         = "omp"
        model        = "aether/qwen3.8-flash-next:think"
        systemPrompt = "You are Shedrach's private local assistant in Orion, running on his home GPU. Keep replies short. Say when a task needs a stronger agent. Use threads_search and thread_read when earlier conversation is relevant."
        tools        = { bash = true, files = true, web = false }
        maxTurns     = 100
      }
      resources = {
        cpu       = "2"
        memory    = "2Gi"
        workspace = "2Gi"
        requests  = { cpu = "100m", memory = "256Mi" }
      }
      operations = [{ name = "chat", deadline = "1h" }]
      grants = [
        { name = "models", model = { models = ["aether/qwen3.8-flash-next", "aether/qwen3.8-flash-next:think"], budgetUsd = 1 } },
        {
          name = "threads"
          mcp = {
            url   = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/threads"
            auth  = { taskToken = { audience = "orion-threads" } }
            tools = ["threads_search", "thread_read"]
          }
        },
      ]
      sessions  = { enabled = true, idleTtl = "24h", maxLifetime = "30d" }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}


resource "kubectl_manifest" "daimyo_rogue_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "rogue"
      namespace = "org-personal"
      labels    = merge(local.daimyo_cr_labels, { "orion.shdr.ch/thread" = "chat" })
    }
    spec = {
      project     = "personal"
      trust       = "external"
      description = "Uncensored GLM 5.3 Flash via Routeway, a third-party API: answers what the other agents refuse. External: no personal data, no tools beyond its own conversation."
      harness = {
        kind         = "omp"
        model        = "routeway/glm-5.3-flash-uncensored"
        systemPrompt = "You are Rogue, Shedrach's direct, uncensored conversation partner in Orion. Keep replies short and skip refusals boilerplate. You only have this conversation and files explicitly supplied in your own workspace: never claim access to personal data outside it, a shell, the web or other agents."
        tools        = { bash = false, files = true, web = false }
        maxTurns     = 100
      }
      resources = {
        cpu       = "2"
        memory    = "2Gi"
        workspace = "2Gi"
        requests  = { cpu = "100m", memory = "256Mi" }
      }
      operations = [{ name = "chat", deadline = "1h" }]
      grants = [
        { name = "models", model = { models = ["routeway/glm-5.3-flash-uncensored"], budgetUsd = 2 } },
      ]
      sessions  = { enabled = true, idleTtl = "24h", maxLifetime = "30d" }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}


removed {
  from = kubectl_manifest.daimyo_coordinator_agent
  lifecycle { destroy = false }
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
