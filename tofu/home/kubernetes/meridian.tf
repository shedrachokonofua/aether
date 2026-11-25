# =============================================================================
# Meridian: MCP and skills gateway
# =============================================================================
# One address for many MCP servers and skill sources, with per-caller access
# (so/meridian). A consumer connects once and sees the tools and Agent Skills it
# may use. Its whole configuration is the `config` value below: issuers,
# sources, endpoints, access. Changing who may use what is a change to this file.
#
# It stands beside LiteLLM's MCP gateway and replaces nothing yet. Pharos is
# reached directly. Every other server is reached through LiteLLM's per-server
# routes for now, with the key the `orion` agent's grants use, so LiteLLM's tool
# allowlists and its 1 MiB and 60 s limits still apply to those. A source moves
# to a direct address one at a time; its tool names do not change when it does,
# because the `<server>-` prefix LiteLLM adds is dropped here.
#
# The skills in so/orion's chart (deploy/helm/orion/skills) are served from the
# pinned commit, under their own names.
#
# Callers are Daimyo agents: a task token minted for audience `meridian` by the
# org's issuer names the agent, and `access` is keyed `daimyo/<agent>`. The
# caller's token stops at Meridian; each source gets its own credential.
#
# Release: so/meridian CI publishes the image `main:<sha>` and the chart
# `0.1.0-g<sha>` from each main commit. Set meridian_release to a commit whose
# pipeline has published both.

locals {
  meridian_namespace = module.namespace["meridian"].name
  meridian_release   = "1dbce959690518026ff4037c8aa87311730615c6"
  meridian_labels = {
    "app.kubernetes.io/name"       = "meridian"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
  # In-cluster address consumers use: `${local.meridian_url}/mcp`.
  meridian_url = "http://meridian.${local.meridian_namespace}.svc.cluster.local:8080"

  # LiteLLM MCP servers the daimyo-orion key may reach
  # (register_litellm_virtual_keys.yml, litellm_daimyo_orion_mcp_servers).
  meridian_litellm_servers = [
    "annas", "clickstack", "comfyui", "espn", "finviz", "fm", "google_maps",
    "homeassistant", "instacart", "jellyfin", "karakeep", "nextcloud",
    "openalex", "openfda", "pubmed", "qbittorrent", "shop", "siren",
    "ticketmaster", "time", "tmdb", "withings", "x_bridge", "yourspotify",
  ]
  # so/orion commit whose chart skills are served.
  meridian_orion_skills_commit = "d6d624c9b7b370860da136e5720bef3226b55406"

  meridian_config = {
    issuers = {
      daimyo = {
        url      = "https://daimyo.home.shdr.ch/orgs/personal"
        audience = "meridian"
        caller   = "agent"
      }
    }
    sources = merge(
      {
        pharos = {
          mcp     = "http://pharos.${local.pharos_namespace}.svc.cluster.local:8080/mcp/"
          headers = { Authorization = "Bearer $PHAROS_MCP_TOKEN" }
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
      "daimyo/orion" = ["*"]
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
    PHAROS_MCP_TOKEN = random_password.pharos_mcp_token.result
    LITELLM_MCP_KEY  = data.vault_kv_secret_v2.meridian_litellm_mcp.data["token"]
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
