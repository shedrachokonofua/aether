# =============================================================================
# Meridian: MCP and skills gateway
# =============================================================================
# One address for many MCP servers and skill sources, with per-caller access
# (so/meridian). A consumer connects once and sees the tools and Agent Skills it
# may use. Its whole configuration is the `config` value below: issuers,
# sources, endpoints, access. Changing who may use what is a change to this file.
#
# It took over from LiteLLM's MCP gateway. A server with its own address is a
# direct source here, with the credential LiteLLM used; the third-party
# servers run in the mcp namespace (mcp.tf). Withings keeps accounts of its own:
# Meridian holds one sign-in to it (`login`), kept on meridian-state.
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
  meridian_release   = "efc48606a05fe078b14e70866b619f48087908a0"
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

  # The servers in the mcp namespace (mcp.tf), each with what it is for,
  # which a caller is told when it connects.
  meridian_mcp_servers = {
    annas         = "Find and download books and scholarly articles."
    comfyui       = "Generate and edit images."
    espn          = "Sports scores, schedules, standings and news."
    finviz        = "Stock screening, fundamentals and market news."
    google-maps   = "Places, directions, travel times and weather."
    homeassistant = "The house: lights, climate, devices, automations and their state."
    jellyfin      = "The home media server: films, shows and music to find and play."
    karakeep      = "Saved bookmarks and reading lists."
    nextcloud     = "Personal files, notes, calendar, contacts and tasks."
    openalex      = "Scholarly works, authors and citations."
    openfda       = "Drug labels, adverse events and recalls."
    pubmed        = "Biomedical literature."
    ticketmaster  = "Live events, venues and tickets."
    time          = "The current time, and conversion between time zones."
    tmdb          = "Films and shows: details, cast, trending."
    yourspotify   = "Spotify listening history and statistics."
  }
  # Of such a server's tools, the ones served, where that is not all of them.
  meridian_mcp_only = {
    # Generation, template, workflow and job tools. Not served: install,
    # update and version switching, model downloads, launch/stop/restart and
    # logs (they act on the server, which has no ComfyUI), partner, auth and
    # billing (Comfy credits), and upload_file (it uploads any file the
    # server can read into ComfyUI's input folder).
    comfyui = [
      "server_info",
      "system_stats",
      "free_memory",
      "generate_image",
      "run_template",
      "run_workflow",
      "job",
      "fetch_outputs",
      "search_templates",
      "get_template",
      "fetch_template",
      "list_workflow_slots",
      "list_workflow_notes",
      "set_workflow_slot",
      "vary_workflow",
      "validate_workflow",
      "nodes",
      "search_models",
    ]
    # DataCanvas is off, but the server still lists the openfda_dataframe_*
    # tools, which only answer canvas_disabled.
    openfda = [
      "openfda_drug_profile",
      "openfda_search_adverse_events",
      "openfda_search_animal_events",
      "openfda_search_drug_shortages",
      "openfda_search_tobacco_reports",
      "openfda_search_recalls",
      "openfda_count_values",
      "openfda_describe_fields",
      "openfda_get_drug_label",
      "openfda_search_drug_approvals",
      "openfda_search_device_clearances",
      "openfda_lookup_ndc",
    ]
    # Search and download, for books and for articles.
    annas = [
      "book_search",
      "article_search",
      "book_download",
      "article_download",
    ]
    # The read tools. Not served: the account writes (update_user_settings,
    # rename_account, generate_public_share_link, revoke_public_access) and
    # analyze_affinity, which needs a signed-in web session.
    yourspotify = [
      "get_track_stats",
      "get_top_tracks",
      "get_artist_stats",
      "get_top_artists",
      "search_listening_history",
      "create_custom_wrapped",
      "get_listening_timeline",
      "get_artist_rank",
      "get_track_rank",
      "analyze_listening_patterns",
      "get_discovery_insights",
      "compare_listening_periods",
      "export_listening_data",
    ]
  }
  # Not served from qBittorrent: shutdown_app, set_app_preferences (autorun
  # programs, WebUI sign-in, save paths) and install_search_plugin (it runs
  # downloaded Python inside the qBittorrent pod).
  meridian_qbittorrent_tools = [
    "list_torrents",
    "manage_torrents",
    "add_torrent",
    "delete_torrent",
    "get_torrent_files",
    "inspect_torrent",
    "get_categories",
    "wait_for_torrent_status",
    "cleanup_completed",
    "mass_rename",
    "find_duplicates",
    "add_trackers",
    "edit_tracker",
    "remove_trackers",
    "rename_folder",
    "set_file_priority",
    "search_torrents",
    "uninstall_search_plugin",
    "enable_search_plugin",
    "update_search_plugins",
    "get_search_plugins",
    "ban_peers",
    "add_rss_feed",
    "get_rss_feeds",
    "set_rss_rule",
    "get_rss_rules",
    "move_rss_item",
    "get_main_log",
    "get_peer_log",
    "get_system_info",
  ]
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
    # Where a person lands after signing a source in, and where the sign-ins
    # are kept (the meridian-state claim).
    url    = local.meridian_public_url
    logins = "/var/lib/meridian/logins.json"
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
        # One sign-in to Shedrach's Withings account, made once in a browser
        # from the link meridian_login gives.
        withings = {
          about = "Health measurements: sleep, weight, activity, heart."
          mcp   = "https://mcp.withings.com/mcp"
          login = true
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
        # qbittorrent-mcp-rs speaks only SSE, and asks for a bearer token.
        qbittorrent = {
          about   = "Torrents on the home server."
          mcp     = "http://qbittorrent.${local.mcp_namespace}.svc.cluster.local:${local.mcp_port["qbittorrent"]}/sse"
          headers = { Authorization = "Bearer $QBITTORRENT_MCP_TOKEN" }
          only    = local.meridian_qbittorrent_tools
        }
        orion-skills = {
          skills = "https://gitlab.home.shdr.ch/so/orion.git#${local.meridian_orion_skills_commit}"
        }
      },
      {
        for server, about in local.meridian_mcp_servers : server => merge(
          {
            mcp   = "http://${server}.${local.mcp_namespace}.svc.cluster.local:${local.mcp_port[server]}/mcp"
            about = about
          },
          contains(keys(local.meridian_mcp_only), server) ? { only = local.meridian_mcp_only[server] } : {},
        )
      },
    )
    access = {
      "daimyo/orion" = ["*"]
      # Orion's other main agent, the same assistant on the molecule runner.
      "daimyo/orion-molecule" = ["*"]
      # orion.tf: dev reads the homelab's telemetry, rogue runs on an external
      # model and gets the home qBittorrent and nothing else.
      "daimyo/dev"   = ["clickstack"]
      "daimyo/rogue" = ["qbittorrent"]
      # so/topaz: CI job records and runner placement via clickstack_sql.
      "daimyo/topaz"    = ["clickstack"]
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

# What must outlive the pod: the sign-ins Meridian holds for sources with a
# `login`. Two pods can mount it, so a new one starts before the old one stops.
resource "kubernetes_persistent_volume_claim_v1" "meridian_state" {
  depends_on = [module.namespace["meridian"], kubernetes_storage_class_v1.cephfs]
  metadata {
    name      = "meridian-state"
    namespace = local.meridian_namespace
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.cephfs.metadata[0].name
    resources { requests = { storage = "1Gi" } }
  }
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
    X_BRIDGE_MCP_TOKEN       = random_password.x_bridge_mcp_token.result
    FM_MCP_TOKEN             = random_password.fm_mcp_token.result
    HYPERDX_MCP_TOKEN        = var.secrets["hyperdx.api_key"]
    SOURCEGULL_MCP_TOKEN     = data.vault_kv_secret_v2.sourcegull_mcp.data["token"]
    HARDCOVER_API_KEY        = var.secrets["hardcover.api_key"]
    QBITTORRENT_MCP_TOKEN    = random_password.litellm_qbit_mcp.result
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
    state            = { claim = kubernetes_persistent_volume_claim_v1.meridian_state.metadata[0].name }
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
