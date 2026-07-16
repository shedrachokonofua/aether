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
  holmes_model_trial    = "aether/qwen3.6-27b:think"
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
resource "kubernetes_secret_v1" "holmes_extra_apis" {
  depends_on = [module.namespace["holmesgpt"]]

  metadata {
    name      = "holmes-extra-apis"
    namespace = local.holmes_ns
  }

  data = {
    "grafana-token" = var.secrets["grafana.holmes_token"]
  }

  type = "Opaque"
}


resource "helm_release" "holmesgpt" {
  depends_on = [kubernetes_secret_v1.holmes_llm, kubernetes_secret_v1.holmes_extra_apis]

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
      { name = "GRAFANA_URL", value = "https://grafana.home.shdr.ch" },
      { name = "LOKI_URL", value = local.holmes_loki_url },
      {
        name = "GRAFANA_TOKEN"
        valueFrom = {
          secretKeyRef = { name = "holmes-extra-apis", key = "grafana-token" }
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
      (local.holmes_model_trial) = {
        api_key     = "{{ env.OPENAI_API_KEY }}"
        api_base    = "{{ env.OPENAI_API_BASE }}"
        model       = "openai/aether/qwen3.6-27b:think"
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
      "aether/grafana" = {
        description = "Query the aether Grafana API (read-only Viewer token): server health, alert-rule health with last evaluation errors, dashboard search. Use grafana_failing_alert_rules to diagnose DatasourceError alerts."
        tools = [
          {
            name        = "grafana_health"
            description = "Check Grafana server health (database status, version)."
            command     = "curl -sS $${GRAFANA_URL}/api/health"
          },
          {
            name        = "grafana_failing_alert_rules"
            description = "List Grafana alert rules that are firing, pending, or unhealthy, including lastError. Primary tool for DatasourceError diagnosis."
            command     = "curl -sS -H \"Authorization: Bearer $${GRAFANA_TOKEN}\" \"$${GRAFANA_URL}/api/prometheus/grafana/api/v1/rules\" | jq '[.data.groups[].rules[] | select(.health != \"ok\" or .state != \"inactive\") | {name, state, health, lastError, lastEvaluation}]'"
          },
          {
            name        = "grafana_search_dashboards"
            description = "Search Grafana dashboards by keyword."
            command     = "curl -sS -H \"Authorization: Bearer $${GRAFANA_TOKEN}\" \"$${GRAFANA_URL}/api/search?query={{ query }}\""
          },
        ]
      }
      "aether/keycloak" = {
        description = "Query Keycloak authentication events from Loki (stream {service_name=\"keycloak\"}). Event lines carry type, realmName, clientId, userId, ipAddress, error. Covers all realms. Only WARN-level events (failures) are logged; successful logins are not."
        tools = [
          {
            name        = "keycloak_login_failures"
            description = "List Keycloak LOGIN_ERROR events from the last N hours (default 6) with user, client, IP, and error reason."
            command     = "curl -sS -G \"$${LOKI_URL}/loki/api/v1/query_range\" --data-urlencode 'query={service_name=\"keycloak\"} |= \"LOGIN_ERROR\"' --data-urlencode 'since={{ hours | default(6) }}h' --data-urlencode 'limit=100' | jq -r '.data.result[].values[][1]'"
          },
          {
            name        = "keycloak_log_search"
            description = "Search the Keycloak server log in Loki for a substring (e.g. an event type like LOGIN_ERROR, a username, an IP, or an error string) over the last N hours (default 6)."
            command     = "curl -sS -G \"$${LOKI_URL}/loki/api/v1/query_range\" --data-urlencode 'query={service_name=\"keycloak\"} |= \"{{ search }}\"' --data-urlencode 'since={{ hours | default(6) }}h' --data-urlencode 'limit=100' | jq -r '.data.result[].values[][1]'"
          },
        ]
      }
    }
  })]
}

resource "kubernetes_cluster_role_v1" "holmes_readonly" {
  metadata {
    name = "holmes-readonly"
  }

  rule {
    api_groups = ["aquasecurity.github.io"]
    resources  = ["vulnerabilityreports", "configauditreports", "exposedsecretreports"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["cilium.io"]
    resources  = ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies", "tracingpolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["snapshot.storage.k8s.io"]
    resources  = ["volumesnapshots", "volumesnapshotcontents", "volumesnapshotclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["certificates", "certificaterequests", "issuers", "clusterissuers"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "holmes_readonly" {
  depends_on = [helm_release.holmesgpt]

  metadata {
    name = "holmes-readonly"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "holmes-holmes-service-account"
    namespace = local.holmes_ns
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.holmes_readonly.metadata[0].name
  }
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
