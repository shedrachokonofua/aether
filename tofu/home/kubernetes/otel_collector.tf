# =============================================================================
# OpenTelemetry Collector for Kubernetes Observability
# =============================================================================
# Exports telemetry to external monitoring stack on Niobe (10.0.2.3)

locals {
  otlp_endpoint      = "https://otel.home.shdr.ch"
  otel_chart_version = "0.114.0"

  # Transform statements to map k8s attributes to existing label conventions
  otel_k8s_label_statements = [
    "set(attributes[\"host.name\"], attributes[\"k8s.node.name\"]) where attributes[\"host.name\"] == nil and attributes[\"k8s.node.name\"] != nil",
    "set(attributes[\"service.name\"], Concat([attributes[\"k8s.namespace.name\"], attributes[\"k8s.pod.name\"]], \"/\")) where attributes[\"service.name\"] == nil and attributes[\"k8s.namespace.name\"] != nil and attributes[\"k8s.pod.name\"] != nil",
  ]

  otel_processors = {
    resource = {
      attributes = [
        { key = "k8s.cluster.name", value = var.cluster_name, action = "insert" }
      ]
    }
    "transform/k8s_labels" = {
      metric_statements = [{ context = "resource", statements = local.otel_k8s_label_statements }]
      log_statements    = [{ context = "resource", statements = local.otel_k8s_label_statements }]
    }
    memory_limiter = {
      check_interval         = "5s"
      limit_percentage       = 80
      spike_limit_percentage = 25
    }
    batch = {
      send_batch_size     = 1000
      send_batch_max_size = 2000
      timeout             = "10s"
    }
  }

  otel_exporters       = { otlphttp = { endpoint = local.otlp_endpoint } }
  otel_resources       = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
  otel_processor_chain = ["memory_limiter", "k8sattributes", "resource", "transform/k8s_labels", "batch"]
}

# =============================================================================
# OTEL Collector - DaemonSet Mode
# =============================================================================

resource "helm_release" "otel_collector_daemonset" {
  depends_on = [helm_release.cilium]

  name             = "otel-daemonset"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  namespace        = kubernetes_namespace_v1.system.metadata[0].name
  version          = local.otel_chart_version
  wait             = true
  timeout          = 600

  values = [yamlencode({
    image = { repository = "otel/opentelemetry-collector-k8s" }
    mode  = "daemonset"

    presets = {
      logsCollection       = { enabled = true, includeCollectorLogs = false }
      kubeletMetrics       = { enabled = true }
      hostMetrics          = { enabled = true }
      kubernetesAttributes = { enabled = true }
    }

    config = {
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }
      processors = local.otel_processors
      exporters  = local.otel_exporters
      service = {
        telemetry = { logs = { level = "warn" } }
        pipelines = {
          logs    = { receivers = ["filelog", "otlp"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
          metrics = { receivers = ["hostmetrics", "kubeletstats", "otlp"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
          traces  = { receivers = ["otlp"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
        }
      }
    }

    resources = local.otel_resources
    ports = {
      otlp      = { enabled = true, containerPort = 4317, servicePort = 4317, protocol = "TCP" }
      otlp-http = { enabled = true, containerPort = 4318, servicePort = 4318, protocol = "TCP" }
    }
  })]
}

# =============================================================================
# OTEL Collector - Deployment Mode
# =============================================================================

resource "helm_release" "otel_collector_deployment" {
  depends_on = [helm_release.cilium]

  name             = "otel-cluster"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  namespace        = kubernetes_namespace_v1.system.metadata[0].name
  version          = local.otel_chart_version
  wait             = true
  timeout          = 600

  values = [yamlencode({
    image        = { repository = "otel/opentelemetry-collector-k8s" }
    mode         = "deployment"
    replicaCount = 1

    presets = {
      clusterMetrics       = { enabled = true }
      kubernetesEvents     = { enabled = true }
      kubernetesAttributes = { enabled = true }
    }

    config = {
      processors = local.otel_processors
      exporters  = local.otel_exporters
      service = {
        telemetry = { logs = { level = "warn" } }
        pipelines = {
          logs    = { receivers = ["k8sobjects"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
          metrics = { receivers = ["k8s_cluster"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
        }
      }
    }

    resources = local.otel_resources
    ports     = { otlp = { enabled = false }, otlp-http = { enabled = false } }
  })]
}
