# =============================================================================
# HolmesGPT - standalone AI incident forensics (CNCF sandbox)
# =============================================================================
# Read-only investigator: the chart manages a get/list/watch-only ClusterRole
# for cluster state; metrics/logs come from ClickHouse (otel.* via
# clickhouse.home.shdr.ch, user agent_reader); LLM access goes through a
# LiteLLM virtual key - Holmes holds no direct provider creds and no write
# credentials of any kind.
#
# In-cluster consumers only (Kestra calls the service API) - no HTTPRoute.
# Server: holmes-holmes.<ns>.svc:80 -> pod :5050, endpoints /api/chat etc.

locals {
  holmes_ns             = module.namespace["holmesgpt"].name
  holmes_chart_version  = "0.35.0"
  holmes_litellm_base   = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
  holmes_model_primary  = "router/glm-5.3"
  holmes_model_local    = "qwen-local"
  holmes_model_trial    = "aether/qwen3.8-flash-next:think"
  holmes_model_cloud    = "qwen-cloud/qwen3.8-max"
  holmes_clickhouse_url = "https://clickhouse.home.shdr.ch"
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
    "grafana-token" = grafana_service_account_token.holmes.key
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "holmes_clickhouse" {
  depends_on = [module.namespace["holmesgpt"]]

  metadata {
    name      = "holmes-clickhouse"
    namespace = local.holmes_ns
  }

  data = {
    "clickhouse-password" = var.secrets["clickhouse.agent_reader_password"]
  }

  type = "Opaque"
}


resource "helm_release" "holmesgpt" {
  depends_on = [kubernetes_secret_v1.holmes_llm, kubernetes_secret_v1.holmes_extra_apis, kubernetes_secret_v1.holmes_clickhouse]

  name             = "holmes"
  repository       = "https://robusta-charts.storage.googleapis.com"
  chart            = "holmes"
  version          = local.holmes_chart_version
  namespace        = local.holmes_ns
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    # robustadev/holmes:0.35.0 is multi-arch; placement is left to the aether-k8s-arch-labeler plus Kyverno.

    # Paused 2026-09-29: from 05:30Z Inquest-driven investigations ran
    # ~20-45 requests/30min against aether/qwen3.8-27b:think, pinning the GPU
    # at its 300 W cap / 84-87 C and re-firing "GPU High Temperature" 81x in 4h
    # (likely a self-sustaining alert -> investigation -> heat loop). Restore
    # to 1 once Inquest stops routing that alert to local-model RCA.
    replicas = 0

    additionalEnvVars = [
      { name = "OPENAI_API_BASE", value = local.holmes_litellm_base },
      {
        name = "OPENAI_API_KEY"
        valueFrom = {
          secretKeyRef = { name = "holmes-llm", key = "openai-api-key" }
        }
      },
      { name = "GRAFANA_URL", value = "https://grafana.home.shdr.ch" },
      { name = "CLICKHOUSE_URL", value = local.holmes_clickhouse_url },
      { name = "CLICKHOUSE_USER", value = "agent_reader" },
      {
        name = "CLICKHOUSE_PASSWORD"
        valueFrom = {
          secretKeyRef = { name = "holmes-clickhouse", key = "clickhouse-password" }
        }
      },
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
    # receives the canonical router/glm-5.3 model ID.

    modelList = {
      (local.holmes_model_primary) = {
        api_key     = "{{ env.OPENAI_API_KEY }}"
        api_base    = "{{ env.OPENAI_API_BASE }}"
        model       = "openai/router/glm-5.3"
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
        model       = "openai/aether/qwen3.8-flash-next:think"
        temperature = 1
      }
      (local.holmes_model_cloud) = {
        api_key     = "{{ env.OPENAI_API_KEY }}"
        api_base    = "{{ env.OPENAI_API_BASE }}"
        model       = "openai/${local.holmes_model_cloud}"
        temperature = 1
      }
    }

    # Deep-merged over chart defaults. Disable bash: alert-driven prompts can
    # carry attacker-controlled annotations/logs (Inquest); keep RO k8s + ClickHouse.
    toolsets = {
      # Requires the Robusta SaaS platform - not deployed here.
      robusta = { enabled = false }
      bash    = { enabled = false }
      "aether/clickhouse" = {
        description = "Read-only ClickHouse SQL on otel.* / aether.* (user agent_reader, max_execution_time=30). Tables: otel.otel_logs(Timestamp,ServiceName,Body,ResourceAttributes,LogAttributes,SeverityText), otel.otel_metrics_gauge / otel_metrics_sum / otel_metrics_histogram(TimeUnix,ServiceName,MetricName,Attributes,ResourceAttributes,Value), otel.otel_traces, aether.namespace_contract(namespace,tier,owner,backup,criticality,exposure). PromQL->SQL: metric=MetricName (prom-scraped keep Prometheus names e.g. node_cpu_seconds_total in otel_metrics_sum, kube_pod_status_phase gauge; OTLP-native dotted e.g. system.cpu.time), job=ServiceName, instance=ResourceAttributes['service.instance.id'], other labels=Attributes['<label>']; gauge latest=argMax(Value,TimeUnix) with 5m lookback; counter rate=deltaSum(Value) per (Attributes,service.instance.id,ServiceName,StartTimeUnix) / window seconds. Logs: ServiceName='<namespace>/<pod>' k8s or hostname for VMs, Body raw line. Always bound by time (TimeUnix/Timestamp > now() - INTERVAL ...) and LIMIT."
        tools = [
          {
            name        = "clickhouse_sql"
            description = "Run a bounded read-only SELECT against ClickHouse (otel.* / aether.*). Only SELECT; always include a time bound (TimeUnix/Timestamp > now() - INTERVAL ...) and LIMIT. max_execution_time=30 enforced server-side."
            command     = "printf '%s' \"{{ query }}\" | head -c 2000 | grep -qiE '^[[:space:]]*(select|with)[[:space:]]' || { echo 'only SELECT/WITH queries allowed'; exit 1; }; printf '%s' \"{{ query }}\" | grep -qiE '\\blimit\\b' || { echo 'LIMIT required'; exit 1; }; curl -sS -u \"$${CLICKHOUSE_USER}:$${CLICKHOUSE_PASSWORD}\" \"$${CLICKHOUSE_URL}/?max_execution_time=30\" --data-binary \"{{ query }}\""
          },
          {
            name        = "clickhouse_logs_search"
            description = "Search ClickHouse logs (otel.otel_logs) for a service (ServiceName, e.g. 'keycloak' or 'holmesgpt/<pod>') containing a substring (case-insensitive) over the last N hours (default 6)."
            command     = "curl -sS -u \"$${CLICKHOUSE_USER}:$${CLICKHOUSE_PASSWORD}\" \"$${CLICKHOUSE_URL}/?max_execution_time=30\" --data-binary \"SELECT Timestamp, ServiceName, SeverityText, substring(Body, 1, 500) AS Body FROM otel.otel_logs WHERE ServiceName = '{{ service }}' AND positionCaseInsensitive(Body, '{{ search }}') > 0 AND Timestamp > now() - INTERVAL {{ hours | default(6) }} HOUR ORDER BY Timestamp DESC LIMIT 100\""
          },
          {
            name        = "clickhouse_metric_latest"
            description = "Latest value per series for a ClickHouse metric (e.g. kube_pod_status_phase, node_cpu_seconds_total, system.cpu.time) over the last 5 minutes. Optional: attribute key (e.g. namespace) and value to filter on; leave empty for no filter."
            command     = "curl -sS -u \"$${CLICKHOUSE_USER}:$${CLICKHOUSE_PASSWORD}\" \"$${CLICKHOUSE_URL}/?max_execution_time=30\" --data-binary \"SELECT ServiceName, Attributes, Value FROM (SELECT ServiceName, Attributes, argMax(Value, TimeUnix) AS Value FROM otel.otel_metrics_gauge WHERE MetricName = '{{ metric }}' AND TimeUnix > now() - INTERVAL 5 MINUTE AND ('{{ attr_key }}' = '' OR Attributes['{{ attr_key }}'] = '{{ attr_value }}') GROUP BY ServiceName, Attributes UNION ALL SELECT ServiceName, Attributes, argMax(Value, TimeUnix) AS Value FROM otel.otel_metrics_sum WHERE MetricName = '{{ metric }}' AND TimeUnix > now() - INTERVAL 5 MINUTE AND ('{{ attr_key }}' = '' OR Attributes['{{ attr_key }}'] = '{{ attr_value }}') GROUP BY ServiceName, Attributes) LIMIT 100\""
          },
        ]
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
        description = "Query Keycloak authentication events from ClickHouse otel.otel_logs (ServiceName='keycloak'). Event lines (Body) carry type, realmName, clientId, userId, ipAddress, error. Covers all realms. Only WARN-level events (failures) are logged; successful logins are not."
        tools = [
          {
            name        = "keycloak_login_failures"
            description = "List Keycloak LOGIN_ERROR events from the last N hours (default 6) with user, client, IP, and error reason."
            command     = "curl -sS -u \"$${CLICKHOUSE_USER}:$${CLICKHOUSE_PASSWORD}\" \"$${CLICKHOUSE_URL}/?max_execution_time=30\" --data-binary \"SELECT Timestamp, substring(Body, 1, 500) AS Body FROM otel.otel_logs WHERE ServiceName = 'keycloak' AND Body LIKE '%LOGIN_ERROR%' AND Timestamp > now() - INTERVAL {{ hours | default(6) }} HOUR ORDER BY Timestamp DESC LIMIT 100\""
          },
          {
            name        = "keycloak_log_search"
            description = "Search the Keycloak server log in ClickHouse (otel.otel_logs, ServiceName='keycloak') for a substring (e.g. an event type like LOGIN_ERROR, a username, an IP, or an error string) over the last N hours (default 6)."
            command     = "curl -sS -u \"$${CLICKHOUSE_USER}:$${CLICKHOUSE_PASSWORD}\" \"$${CLICKHOUSE_URL}/?max_execution_time=30\" --data-binary \"SELECT Timestamp, substring(Body, 1, 500) AS Body FROM otel.otel_logs WHERE ServiceName = 'keycloak' AND positionCaseInsensitive(Body, '{{ search }}') > 0 AND Timestamp > now() - INTERVAL {{ hours | default(6) }} HOUR ORDER BY Timestamp DESC LIMIT 100\""
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

# Restrict Holmes API to Kestra (Inquest); system ns for the webhook probes.
resource "kubernetes_manifest" "holmes_ingress_policy" {
  depends_on = [helm_release.holmesgpt, module.namespace["kestra"]]

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
              "io.kubernetes.pod.namespace" = "system"
            }
          }]
        },
      ]
    }
  }
}
