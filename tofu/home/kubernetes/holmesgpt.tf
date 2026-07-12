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
  holmes_model_primary  = "router/glm-5.2"
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
    # Holmes uses openai/ as its local LiteLLM transport prefix; the proxy
    # receives the canonical router/glm-5.2 model ID.
    modelList = {
      (local.holmes_model_primary) = {
        api_key     = "{{ env.OPENAI_API_KEY }}"
        api_base    = "{{ env.OPENAI_API_BASE }}"
        model       = "openai/router/glm-5.2"
        temperature = 1
      }
      (local.holmes_model_local) = {
        api_key     = "{{ env.OPENAI_API_KEY }}"
        api_base    = "{{ env.OPENAI_API_BASE }}"
        model       = "openai/aether/qwen3.6-35b-a3b:think"
        temperature = 1
      }
    }

    # Deep-merged over chart defaults. Disable bash: alert-driven prompts can
    # carry attacker-controlled annotations/logs (Inquest); keep RO k8s + Prom/Loki.
    toolsets = {
      # Requires the Robusta SaaS platform - not deployed here.
      robusta = { enabled = false }
      bash    = { enabled = false }
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

# Restrict Holmes API to Kestra (Inquest) and Hermes (tungsten interactive).
resource "kubernetes_manifest" "holmes_ingress_policy" {
  depends_on = [helm_release.holmesgpt, module.namespace["kestra"], module.namespace["hermes"]]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "holmes-api-ingress"
      namespace = local.holmes_ns
    }
    spec = {
      endpointSelector = {
        matchLabels = { app = "holmes" }
      }
      ingress = [
        {
          fromEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = module.namespace["kestra"].name
            }
          }]
          toPorts = [{
            ports = [{ port = "5050", protocol = "TCP" }]
          }]
        },
        {
          fromEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = module.namespace["hermes"].name
            }
          }]
          toPorts = [{
            ports = [{ port = "5050", protocol = "TCP" }]
          }]
        },
        {
          fromEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = "system"
            }
          }]
        },
      ]
    }
  }
}
