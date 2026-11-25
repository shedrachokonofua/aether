# =============================================================================
# Meridian: MCP and skills gateway
# =============================================================================
# One address for many MCP servers and skill sources, with per-caller access
# (so/meridian). A consumer connects once and sees the tools and Agent Skills it
# may use. Its whole configuration is the `config` value below: issuers,
# sources, endpoints, access. Changing who may use what is a change to this file.
#
# It is taking over from LiteLLM's MCP gateway, one server at a time. A server
# with its own address is a direct source here, with the credential LiteLLM
# used. The servers that are still sidecars in LiteLLM's pod
# (meridian_litellm_servers) are reached through LiteLLM's per-server routes
# until their containers move, with the key the `orion` agent's grants use, so
# LiteLLM's tool allowlists and its 1 MiB and 60 s limits still apply to those.
# A tool's name does not change when its server moves: the `<server>-` prefix
# LiteLLM adds is dropped here.
#
# pop gives roles to whoever calls it and Deskplane keeps each caller's
# sessions apart, so each is told the caller by the caller's own issuer.
# Meridian exchanges the token it was given (RFC 8693) for one addressed to
# the server: a person's at Keycloak, as client meridian-exchange
# (keycloak.tf), and an agent's at the Daimyo org's token endpoint
# (daimyo.tf `tokenExchange`). Meridian signs nothing and neither server
# trusts it as an issuer; it reaches Keycloak or Daimyo on each such call,
# with the result kept until the token nears expiry.
#
# The skills in so/orion's chart (deploy/helm/orion/skills) are served from the
# pinned commit, under their own names.
#
# Callers are Daimyo agents and his own computers. An agent's task token, minted
# for audience `meridian` by the org's issuer, names the agent: `daimyo/<agent>`.
# An MCP client on a computer signs in through Keycloak (client meridian-mcp,
# keycloak.tf) and is `keycloak/<username>`. The caller's token stops at
# Meridian; each source gets its own credential.
#
# Release: so/meridian CI publishes the image `main:<sha>` and the chart
# `0.1.0-g<sha>` from each main commit. Set meridian_release to a commit whose
# pipeline has published both.

locals {
  meridian_namespace = module.namespace["meridian"].name
  meridian_release   = "fc0b941ec1ace113e67584b4a4a321cf059940c9"
  meridian_labels = {
    "app.kubernetes.io/name"       = "meridian"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
  # Address for his computers, on the internal listener. A Keycloak token's
  # audience is `${local.meridian_public_url}/mcp` (keycloak.tf).
  meridian_host       = "meridian.home.shdr.ch"
  meridian_public_url = "https://${local.meridian_host}"
  # In-cluster address consumers use: `${local.meridian_url}/mcp`.
  meridian_url = "http://meridian.${local.meridian_namespace}.svc.cluster.local:8080"

  # LiteLLM MCP servers the daimyo-orion key may reach
  # (register_litellm_virtual_keys.yml, litellm_daimyo_orion_mcp_servers).
  # Each with what it is for, which a caller is told when it connects.
  meridian_litellm_servers = {
    annas         = "Find and download books and scholarly articles."
    comfyui       = "Generate and edit images."
    espn          = "Sports scores, schedules, standings and news."
    finviz        = "Stock screening, fundamentals and market news."
    google_maps   = "Places, directions, travel times and weather."
    homeassistant = "The house: lights, climate, devices, automations and their state."
    jellyfin      = "The home media server: films, shows and music to find and play."
    karakeep      = "Saved bookmarks and reading lists."
    nextcloud     = "Personal files, notes, calendar, contacts and tasks."
    openalex      = "Scholarly works, authors and citations."
    openfda       = "Drug labels, adverse events and recalls."
    pubmed        = "Biomedical literature."
    qbittorrent   = "Torrents on the home server."
    ticketmaster  = "Live events, venues and tickets."
    time          = "The current time, and conversion between time zones."
    tmdb          = "Films and shows: details, cast, trending."
    withings      = "Health measurements: sleep, weight, activity, heart."
    yourspotify   = "Spotify listening history and statistics."
  }
  # The read tools LiteLLM's allowlist served from ClickStack, without the
  # `clickstack_` every one of them starts with.
  meridian_clickstack_tools = [
    "list_sources", "describe_source", "list_metrics", "describe_metric",
    "get_alert", "get_dashboard", "get_dashboard_tile", "search_dashboards",
    "query_tile", "query_tiles", "get_saved_search", "timeseries", "table",
    "search", "event_patterns", "event_deltas", "emerging_signals", "sql",
    "trace_waterfall", "trace_top_time_consuming_operations",
  ]
  # so/orion commit whose chart skills are served.
  meridian_orion_skills_commit = "39778d5bb16af53e11f3053e77efc026503db13b"

  meridian_config = {
    # Finding a tool by what it is for: LiteLLM's embedding and reranking
    # models, with a key that may use those two and nothing else.
    search = {
      models = "http://litellm.litellm.svc.cluster.local:4000/v1"
      key    = "$MERIDIAN_SEARCH_KEY"
      embed  = "aether/qwen3-embedding:0.6b"
      rerank = "aether/qwen3-reranker-4b"
    }
    issuers = {
      daimyo = {
        url      = "https://daimyo.home.shdr.ch/orgs/personal"
        audience = "meridian"
        caller   = "agent"
        # The org's token endpoint exchanges a task token for one addressed
        # to a source (daimyo.tf `tokenExchange`); the task token itself is
        # the credential, so there is no client.
        exchange = true
      }
      keycloak = {
        url      = "https://auth.shdr.ch/realms/aether"
        audience = "${local.meridian_public_url}/mcp"
        caller   = "preferred_username"
        # The realm roles a person holds, for `roles` below. OpenWebUI's
        # tokens carry them (keycloak.tf openwebui_roles).
        roles = "roles"
        # Keycloak exchanges a person's token for one addressed to a source
        # (`exchange` sources below), with Meridian as client
        # meridian-exchange (keycloak.tf).
        exchange = { client = "meridian-exchange", secret = "$MERIDIAN_EXCHANGE_SECRET" }
      }
    }
    sources = merge(
      {
        # A server whose tools all start with its own name is served without
        # the repetition: pharos_list_books, not pharos_pharos_list_books.
        pharos = {
          about   = "The personal library: search and read books, and the skills made from finished ones."
          mcp     = "http://pharos.${local.pharos_namespace}.svc.cluster.local:8080/mcp/"
          headers = { Authorization = "Bearer $PHAROS_MCP_TOKEN" }
          tools   = { "pharos_*" = { name = "*" } }
        }
        x-bridge = {
          about   = "The archive of X (Twitter) bookmarks and other collections: search and read tweets."
          mcp     = "http://x-bridge.x-bridge.svc.cluster.local/mcp"
          headers = { Authorization = "Bearer $X_BRIDGE_MCP_TOKEN" }
        }
        fm = {
          about   = "The running Football Manager save: read and change the game."
          mcp     = "http://fm-mcp.games.svc.cluster.local:18766/mcp"
          headers = { Authorization = "Bearer $FM_MCP_TOKEN" }
          tools   = { "fm_*" = { name = "*" } }
        }
        clickstack = {
          about   = "The homelab's logs, traces and metrics. Read only."
          mcp     = "http://hyperdx.hyperdx.svc.cluster.local:3000/api/mcp"
          headers = { Authorization = "Bearer $HYPERDX_MCP_TOKEN" }
          tools   = { "clickstack_*" = { name = "*" } }
          only    = local.meridian_clickstack_tools
        }
        sourcegull = {
          about   = "Code search across every repository: search, read files, find symbols."
          mcp     = "http://sourcegull-web.sourcegull.svc.cluster.local:7080/.api/mcp"
          headers = { Authorization = "Bearer $SOURCEGULL_MCP_TOKEN" }
        }
        instacart = {
          about = "Grocery shopping: carts, items and orders."
          mcp   = "http://instacart-mcp.instacart-mcp.svc.cluster.local:8080/mcp"
          tools = { "instacart_*" = { name = "*" } }
        }
        siren = {
          about = "The music library and its ratings: albums, artists, similar albums, recommendations."
          mcp   = "http://siren-mcp.siren.svc.cluster.local:8082/mcp"
        }
        shop = {
          about = "Shopping across online stores: find products, carts, checkout."
          mcp   = "https://mcp.shop.com/"
        }
        # Deskplane keeps each caller's sessions apart and pop gives roles to
        # whoever calls it, so each is told the caller by the caller's own
        # issuer: Meridian exchanges the token it was given for one addressed
        # to the server (RFC 8693, `exchange` on the issuers above).
        deskplane = {
          about    = "Remote desktops, browsers and phones to see and operate."
          mcp      = "http://deskplane-mcp.deskplane.svc.cluster.local:8100/mcp"
          exchange = "deskplane"
          timeout  = "30m"
        }
        pop = {
          about    = "The deploy platform: projects, deploys, aliases and rollbacks."
          mcp      = "https://pop.home.shdr.ch/mcp/aether"
          exchange = "pop"
        }
        # Hardcover has no MCP server or OpenAPI spec, only GraphQL: served as
        # hardcover_search, _describe, _query and _mutate.
        hardcover = {
          about   = "Books read and to read, on Hardcover."
          graphql = "https://api.hardcover.app/v1/graphql"
          headers = { Authorization = "Bearer $HARDCOVER_API_KEY" }
        }
        orion-skills = {
          skills = "https://gitlab.home.shdr.ch/so/orion.git#${local.meridian_orion_skills_commit}"
        }
      },
      {
        # A source name has no underscore (a tool is <source>_<tool>).
        for server, about in local.meridian_litellm_servers : replace(server, "_", "-") => {
          mcp     = "http://litellm.litellm.svc.cluster.local:4000/mcp/${server}"
          about   = about
          headers = { "x-litellm-api-key" = "Bearer $LITELLM_MCP_KEY" }
          tools   = { "${server}-*" = { name = "*" } }
        }
      },
    )
    access = {
      "daimyo/orion" = ["*"]
      # orion.tf: dev reads the homelab's telemetry, rogue runs on an external
      # model and gets the home qBittorrent and nothing else.
      "daimyo/dev"      = ["clickstack"]
      "daimyo/rogue"    = ["qbittorrent"]
      "keycloak/shdrch" = ["*"]
    }
    # Whoever may sign in to OpenWebUI (OAUTH_ALLOWED_ROLES, openwebui.tf)
    # gets, as themselves, the sources that only read public information:
    # nothing of the home, nothing that is one person's account.
    roles = {
      "keycloak/openwebui-user" = [
        "time", "tmdb", "espn", "finviz", "ticketmaster",
        "openalex", "pubmed", "openfda", "google-maps",
      ]
    }
  }
}

# The `orion` agent's LiteLLM key for the MCP gateway's per-server routes
# (openbao_daimyo.tf). Meridian reaches LiteLLM's servers with the same key
# and scope until each is a direct source.
data "vault_kv_secret_v2" "meridian_litellm_mcp" {
  mount = "kv"
  name  = "orgs/personal/litellm-mcp"
}

# The credentials the configuration names as $NAME.
resource "kubernetes_secret_v1" "meridian_env" {
  depends_on = [module.namespace["meridian"]]

  metadata {
    name      = "meridian-env"
    namespace = local.meridian_namespace
    labels    = local.meridian_labels
  }

  data = {
    PHAROS_MCP_TOKEN         = random_password.pharos_mcp_token.result
    LITELLM_MCP_KEY          = data.vault_kv_secret_v2.meridian_litellm_mcp.data["token"]
    X_BRIDGE_MCP_TOKEN       = random_password.x_bridge_mcp_token.result
    FM_MCP_TOKEN             = random_password.fm_mcp_token.result
    HYPERDX_MCP_TOKEN        = var.secrets["hyperdx.api_key"]
    SOURCEGULL_MCP_TOKEN     = data.vault_kv_secret_v2.sourcegull_mcp.data["token"]
    HARDCOVER_API_KEY        = var.secrets["hardcover.api_key"]
    MERIDIAN_EXCHANGE_SECRET = var.meridian_exchange_client_secret
    MERIDIAN_SEARCH_KEY      = var.secrets["litellm.virtual_keys.meridian"]
  }
}

resource "kubernetes_secret_v1" "meridian_registry" {
  depends_on = [module.namespace["meridian"]]

  metadata {
    name      = "meridian-gitlab-registry"
    namespace = local.meridian_namespace
    labels    = local.meridian_labels
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

resource "helm_release" "meridian" {
  depends_on = [
    kubernetes_secret_v1.meridian_env,
    kubernetes_secret_v1.meridian_registry,
  ]

  name       = "meridian"
  repository = "oci://${local.gitlab_registry_host}/so/meridian/charts"
  chart      = "meridian"
  version    = "0.1.0-g${local.meridian_release}"
  namespace  = local.meridian_namespace
  wait       = true
  atomic     = true
  timeout    = 300

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{40}$", local.meridian_release))
      error_message = "meridian_release must be the full commit sha so/meridian CI published an image and a chart for."
    }
  }

  values = [yamlencode({
    image = {
      repository = "${local.gitlab_registry_host}/so/meridian/main"
      tag        = local.meridian_release
    }
    imagePullSecrets = [{ name = kubernetes_secret_v1.meridian_registry.metadata[0].name }]
    existingSecret   = kubernetes_secret_v1.meridian_env.metadata[0].name
    # A changed `config` is taken up by the running pod. A rotated source
    # credential is not: restart the Deployment after rotating one.
    env = {
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318"
    }
    config = local.meridian_config
  })]
}

# --- Private route -----------------------------------------------------------
# *.home.shdr.ch internal listener; the namespace's exposure=internal gives it
# gateway-access. Meridian refuses every request without a token it can verify.
resource "kubernetes_manifest" "meridian_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.meridian]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "meridian"
      namespace = local.meridian_namespace
      labels    = local.meridian_labels
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.meridian_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "meridian"
          port = 8080
        }]
      }]
    }
  }
}
