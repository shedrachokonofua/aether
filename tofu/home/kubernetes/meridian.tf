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
# sessions apart, so Meridian signs each request to them with a token naming
# the caller (`sign`). pop.tf and deskplane.tf trust Meridian as an issuer, at
# its own address, with the key below.
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
  meridian_release   = "709625596bd1a8b6f026d6ec996eed5ea7ba8262"
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
  meridian_litellm_servers = [
    "annas", "comfyui", "espn", "finviz", "google_maps", "homeassistant",
    "jellyfin", "karakeep", "nextcloud", "openalex", "openfda", "pubmed",
    "qbittorrent", "ticketmaster", "time", "tmdb", "withings", "yourspotify",
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
    # Its own address and key: the issuer of the tokens it signs for `sign`
    # sources.
    url = local.meridian_public_url
    key = "$MERIDIAN_SIGNING_KEY"
    issuers = {
      daimyo = {
        url      = "https://daimyo.home.shdr.ch/orgs/personal"
        audience = "meridian"
        caller   = "agent"
      }
      keycloak = {
        url      = "https://auth.shdr.ch/realms/aether"
        audience = "${local.meridian_public_url}/mcp"
        caller   = "preferred_username"
      }
    }
    sources = merge(
      {
        # A server whose tools all start with its own name is served without
        # the repetition: pharos_list_books, not pharos_pharos_list_books.
        pharos = {
          mcp     = "http://pharos.${local.pharos_namespace}.svc.cluster.local:8080/mcp/"
          headers = { Authorization = "Bearer $PHAROS_MCP_TOKEN" }
          tools   = { "pharos_*" = { name = "*" } }
        }
        x-bridge = {
          mcp     = "http://x-bridge.x-bridge.svc.cluster.local/mcp"
          headers = { Authorization = "Bearer $X_BRIDGE_MCP_TOKEN" }
        }
        fm = {
          mcp     = "http://fm-mcp.games.svc.cluster.local:18766/mcp"
          headers = { Authorization = "Bearer $FM_MCP_TOKEN" }
          tools   = { "fm_*" = { name = "*" } }
        }
        clickstack = {
          mcp     = "http://hyperdx.hyperdx.svc.cluster.local:3000/api/mcp"
          headers = { Authorization = "Bearer $HYPERDX_MCP_TOKEN" }
          tools   = { "clickstack_*" = { name = "*" } }
          only    = local.meridian_clickstack_tools
        }
        sourcegull = {
          mcp     = "http://sourcegull-web.sourcegull.svc.cluster.local:7080/.api/mcp"
          headers = { Authorization = "Bearer $SOURCEGULL_MCP_TOKEN" }
        }
        instacart = {
          mcp   = "http://instacart-mcp.instacart-mcp.svc.cluster.local:8080/mcp"
          tools = { "instacart_*" = { name = "*" } }
        }
        siren = {
          mcp = "http://siren-mcp.siren.svc.cluster.local:8082/mcp"
        }
        shop = {
          mcp = "https://mcp.shop.com/"
        }
        deskplane = {
          mcp     = "http://deskplane-mcp.deskplane.svc.cluster.local:8100/mcp"
          sign    = "deskplane"
          timeout = "30m"
        }
        pop = {
          mcp  = "https://pop.home.shdr.ch/mcp/aether"
          sign = "pop"
        }
        orion-skills = {
          skills = "https://gitlab.home.shdr.ch/so/orion.git#${local.meridian_orion_skills_commit}"
        }
      },
      {
        # A source name has no underscore (a tool is <source>_<tool>).
        for server in local.meridian_litellm_servers : replace(server, "_", "-") => {
          mcp     = "http://litellm.litellm.svc.cluster.local:4000/mcp/${server}"
          headers = { "x-litellm-api-key" = "Bearer $LITELLM_MCP_KEY" }
          tools   = { "${server}-*" = { name = "*" } }
        }
      },
    )
    access = {
      "daimyo/orion"    = ["*"]
      "keycloak/shdrch" = ["*"]
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

# The key Meridian signs caller tokens with. Kept, so that Meridian is the same
# issuer after a restart and the keys pop and Deskplane have cached stay good.
resource "tls_private_key" "meridian_signing" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
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
    PHAROS_MCP_TOKEN     = random_password.pharos_mcp_token.result
    LITELLM_MCP_KEY      = data.vault_kv_secret_v2.meridian_litellm_mcp.data["token"]
    X_BRIDGE_MCP_TOKEN   = random_password.x_bridge_mcp_token.result
    FM_MCP_TOKEN         = random_password.fm_mcp_token.result
    HYPERDX_MCP_TOKEN    = var.secrets["hyperdx.api_key"]
    SOURCEGULL_MCP_TOKEN = data.vault_kv_secret_v2.sourcegull_mcp.data["token"]
    MERIDIAN_SIGNING_KEY = tls_private_key.meridian_signing.private_key_pem_pkcs8
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
