# =============================================================================
# Meridian: MCP and skills gateway
# =============================================================================
# One address for many MCP servers and skill sources, with per-caller access
# (so/meridian). A consumer connects once and sees the tools and Agent Skills it
# may use. Its whole configuration is the `config` value below: issuers,
# sources, endpoints, access. Changing who may use what is a change to this file.
#
# It stands beside LiteLLM's MCP gateway and replaces nothing yet: sources move
# over one at a time. Pharos is the first.
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
  meridian_release   = "1989b4cc78a9ebb8a4611ee44bbc063a43b58b07"
  meridian_labels = {
    "app.kubernetes.io/name"       = "meridian"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
  # In-cluster address consumers use: `${local.meridian_url}/mcp`.
  meridian_url = "http://meridian.${local.meridian_namespace}.svc.cluster.local:8080"

  meridian_config = {
    issuers = {
      daimyo = {
        url      = "https://daimyo.home.shdr.ch/orgs/personal"
        audience = "meridian"
        caller   = "agent"
      }
    }
    sources = {
      pharos = {
        mcp     = "http://pharos.${local.pharos_namespace}.svc.cluster.local:8080/mcp/"
        headers = { Authorization = "Bearer $PHAROS_MCP_TOKEN" }
      }
    }
    access = {
      "daimyo/orion" = ["*"]
    }
  }
}

# The credentials the configuration names as $NAME. One per source.
resource "kubernetes_secret_v1" "meridian_env" {
  depends_on = [module.namespace["meridian"]]

  metadata {
    name      = "meridian-env"
    namespace = local.meridian_namespace
    labels    = local.meridian_labels
  }

  data = {
    PHAROS_MCP_TOKEN = random_password.pharos_mcp_token.result
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
