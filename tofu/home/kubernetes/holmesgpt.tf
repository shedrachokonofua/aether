# =============================================================================
# HolmesGPT - standalone AI incident forensics (CNCF sandbox)
# =============================================================================
# Read-only investigator: the chart manages a get/list/watch-only ClusterRole
# for cluster state; metrics/logs come from the monitoring VM (Prometheus/Loki
# via LAN); LLM access goes through a LiteLLM virtual key - Holmes holds no
# direct provider creds and no write credentials of any kind.
#
# In-cluster consumers only (tungsten calls the service API) - no HTTPRoute.
# Server: holmes-holmes.<ns>.svc:80 -> pod :5050, endpoints /api/chat etc.

locals {
  holmes_ns             = module.namespace["holmesgpt"].name
  holmes_chart_version  = "0.35.0"
  holmes_litellm_base   = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
  holmes_model_primary  = "glm"
  holmes_model_local    = "qwen-local"
  holmes_prometheus_url = "https://prometheus.home.shdr.ch"
  holmes_loki_url       = "https://loki.home.shdr.ch"
}

# LiteLLM virtual key (minted against /key/generate, stored in SOPS).
resource "kubernetes_secret_v1" "holmes_llm" {
  depends_on = [module.namespace["holmesgpt"]]

  metadata {
    name      = "holmes-llm"
    namespace = local.holmes_ns
  }

  data = {
    "openai-api-key" = var.secrets["litellm.virtual_keys.holmes"]
  }

  type = "Opaque"
}

resource "helm_release" "holmesgpt" {
  depends_on = [kubernetes_secret_v1.holmes_llm]

  name             = "holmes"
  repository       = "https://robusta-charts.storage.googleapis.com"
  chart            = "holmes"
  version          = local.holmes_chart_version
  namespace        = local.holmes_ns
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    # Mixed-arch cluster; upstream image is amd64.
    nodeSelector = { "kubernetes.io/arch" = "amd64" }

    additionalEnvVars = [
      { name = "OPENAI_API_BASE", value = local.holmes_litellm_base },
      {
        name = "OPENAI_API_KEY"
        valueFrom = {
          secretKeyRef = { name = "holmes-llm", key = "openai-api-key" }
        }
      },
      # Default model for investigations that don't pass one explicitly.
      { name = "MODEL", value = local.holmes_model_primary },
    ]

    # {{ env.* }} below is Holmes-side Jinja, resolved in-pod at load time.
    modelList = {
      (local.holmes_model_primary) = {
        api_key     = "{{ env.OPENAI_API_KEY }}"
        api_base    = "{{ env.OPENAI_API_BASE }}"
        model       = "openai/zai/glm-5.2"
        temperature = 1
      }
      (local.holmes_model_local) = {
        api_key     = "{{ env.OPENAI_API_KEY }}"
        api_base    = "{{ env.OPENAI_API_BASE }}"
        model       = "openai/aether/qwen3.6-35b-a3b:think"
        temperature = 1
      }
    }

    # Deep-merged over chart defaults (kubernetes/core+logs, internet, bash
    # stay enabled with the chart's read-only ServiceAccount).
    toolsets = {
      # Requires the Robusta SaaS platform - not deployed here.
      robusta = { enabled = false }
      "prometheus/metrics" = {
        enabled = true
        subtype = "prometheus"
        config  = { prometheus_url = local.holmes_prometheus_url }
      }
      # Direct Loki connection (no Grafana proxy, no token needed).
      "grafana/loki" = {
        enabled = true
        config  = { api_url = local.holmes_loki_url }
      }
    }
  })]
}
