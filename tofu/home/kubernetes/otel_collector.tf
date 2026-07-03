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
    # Keep namespace on all k8s telemetry so central Janus can enforce tenant scoping.
    "set(attributes[\"service.namespace\"], attributes[\"k8s.namespace.name\"]) where attributes[\"service.namespace\"] == nil and attributes[\"k8s.namespace.name\"] != nil",
    # Host-side seven30 vcluster namespaces should map to canonical tenant namespace.
    "set(attributes[\"service.namespace\"], \"seven30\") where IsMatch(attributes[\"k8s.namespace.name\"], \"^vc-seven30($|-).*\")",
  ]

  otel_processors = {
    resource = {
      attributes = [
        { key = "k8s.cluster.name", value = var.cluster_name, action = "insert" }
      ]
    }
    "transform/k8s_labels" = {
      metric_statements = [
        { context = "resource", statements = local.otel_k8s_label_statements },
        # Istio Ambient: map vc-seven30 workload namespaces to canonical tenant for Janus scoping
        {
          context = "datapoint"
          statements = [
            "set(resource.attributes[\"service.namespace\"], \"seven30\") where attributes[\"destination_workload_namespace\"] == \"vc-seven30\"",
            "set(resource.attributes[\"service.namespace\"], \"seven30\") where attributes[\"source_workload_namespace\"] == \"vc-seven30\"",
          ]
        },
      ]
      log_statements = [{ context = "resource", statements = local.otel_k8s_label_statements }]
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

  otel_exporters           = { otlphttp = { endpoint = local.otlp_endpoint } }
  otel_resources           = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
  otel_daemonset_resources = { requests = { cpu = "50m", memory = "64Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
  otel_processor_chain     = ["memory_limiter", "k8sattributes", "resource", "transform/k8s_labels", "batch"]
}

# =============================================================================
# OTEL Collector - DaemonSet Mode
# =============================================================================

resource "helm_release" "otel_collector_daemonset" {
  depends_on = [
    helm_release.cilium,
    kubernetes_priority_class_v1.node_agent,
  ]

  name       = "otel-daemonset"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  namespace  = module.namespace["system"].name
  version    = local.otel_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    image = { repository = "otel/opentelemetry-collector-k8s" }
    mode  = "daemonset"

    priorityClassName = local.node_agent_priority_class

    extraEnvs = [
      {
        name = "K8S_NODE_NAME"
        valueFrom = {
          fieldRef = {
            fieldPath = "spec.nodeName"
          }
        }
      },
      {
        name = "K8S_NODE_IP"
        valueFrom = {
          fieldRef = {
            fieldPath = "status.hostIP"
          }
        }
      }
    ]

    presets = {
      logsCollection       = { enabled = true, includeCollectorLogs = false }
      kubeletMetrics       = { enabled = true }
      hostMetrics          = { enabled = true }
      kubernetesAttributes = { enabled = true }
    }

    clusterRole = {
      create = true
      rules = [
        {
          apiGroups = [""]
          resources = ["nodes/metrics", "nodes/proxy"]
          verbs     = ["get"]
        }
      ]
    }

    config = {
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
        prometheus = {
          config = {
            scrape_configs = [
              {
                # cAdvisor metrics retain namespace/pod/container labels that
                # VPA's Prometheus history provider needs for per-container
                # recommendations. kubeletstats is useful for dashboards, but
                # it is not enough for VPA history on multi-container pods.
                job_name          = "kubelet-cadvisor"
                scrape_interval   = "30s"
                scheme            = "https"
                metrics_path      = "/metrics/cadvisor"
                bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
                tls_config = {
                  insecure_skip_verify = true
                }
                static_configs = [{
                  targets = ["$${env:K8S_NODE_IP}:10250"]
                }]
              }
            ]
          }
        }
        # Explicit kubelet receiver config so container/node CPU usage metrics are always collected.
        kubeletstats = {
          collection_interval  = "20s"
          auth_type            = "serviceAccount"
          endpoint             = "https://$${env:K8S_NODE_IP}:10250"
          insecure_skip_verify = true
          metric_groups        = ["node", "pod", "container"]
        }
      }
      processors = local.otel_processors
      exporters  = local.otel_exporters
      service = {
        telemetry = { logs = { level = "warn" } }
        pipelines = {
          logs    = { receivers = ["filelog", "otlp"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
          metrics = { receivers = ["hostmetrics", "kubeletstats", "otlp", "prometheus"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
          traces  = { receivers = ["otlp"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
        }
      }
    }

    resources = local.otel_daemonset_resources
    ports = {
      otlp      = { enabled = true, containerPort = 4317, servicePort = 4317, protocol = "TCP" }
      otlp-http = { enabled = true, containerPort = 4318, servicePort = 4318, protocol = "TCP" }
    }
  })]
}

resource "kubernetes_service_v1" "otel_collector_daemonset" {
  depends_on = [helm_release.otel_collector_daemonset]

  metadata {
    name      = "otel-daemonset-opentelemetry-collector"
    namespace = module.namespace["system"].name
    labels = {
      "app.kubernetes.io/instance" = "otel-daemonset"
      "app.kubernetes.io/name"     = "opentelemetry-collector"
      "component"                  = "agent-collector"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/instance" = "otel-daemonset"
      "app.kubernetes.io/name"     = "opentelemetry-collector"
      "component"                  = "agent-collector"
    }

    port {
      name        = "otlp"
      port        = 4317
      target_port = "otlp"
      protocol    = "TCP"
    }

    port {
      name        = "otlp-http"
      port        = 4318
      target_port = "otlp-http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# OTEL Collector - Deployment Mode
# =============================================================================

resource "helm_release" "otel_collector_deployment" {
  depends_on = [
    helm_release.cilium,
    helm_release.ztunnel,
    helm_release.tetragon,
    helm_release.trivy_operator,
    helm_release.policy_reporter,
    helm_release.kepler,
  ]

  name       = "otel-cluster"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  namespace  = module.namespace["system"].name
  version    = local.otel_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    image        = { repository = "otel/opentelemetry-collector-k8s" }
    mode         = "deployment"
    replicaCount = 1

    presets = {
      clusterMetrics       = { enabled = true }
      kubernetesEvents     = { enabled = true }
      kubernetesAttributes = { enabled = true }
    }

    # The kubernetesAttributes preset's ClusterRole omits endpoints/services,
    # so any prometheus scrape job using kubernetes_sd_configs role=endpoints
    # silently fails with "endpoints is forbidden". Grant them explicitly.
    clusterRole = {
      create = true
      rules = [
        {
          apiGroups = [""]
          resources = ["endpoints", "services", "pods", "nodes", "namespaces"]
          verbs     = ["get", "list", "watch"]
        },
        {
          apiGroups = ["discovery.k8s.io"]
          resources = ["endpointslices"]
          verbs     = ["get", "list", "watch"]
        },
      ]
    }

    config = {
      receivers = {
        prometheus = {
          config = {
            scrape_configs = [
              {
                job_name        = "istiod"
                scrape_interval = "30s"
                static_configs = [{
                  targets = ["istiod.istio-system.svc.cluster.local:15014"]
                }]
              },
              {
                # Cilium Hubble L7/L4 metrics — `hubble_*` series with
                # source/destination workload labels. Cilium-agent exposes
                # them on :9965 when hubble.metrics.enabled is set (see
                # cilium.tf). Same DaemonSet pattern as ztunnel below.
                job_name        = "hubble"
                scrape_interval = "30s"
                kubernetes_sd_configs = [{
                  role       = "pod"
                  namespaces = { names = ["kube-system"] }
                }]
                relabel_configs = [
                  {
                    source_labels = ["__meta_kubernetes_pod_label_k8s_app"]
                    action        = "keep"
                    regex         = "cilium"
                  },
                  {
                    source_labels = ["__address__"]
                    action        = "replace"
                    regex         = "([^:]+)(?::\\d+)?"
                    replacement   = "$$1:9965"
                    target_label  = "__address__"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_node_name"]
                    target_label  = "node"
                  },
                ]
              },
              {
                # ztunnel is a DaemonSet with no Service in front — the
                # previous endpoints-based scrape silently matched nothing.
                # Discover pods directly and target the ztunnel-stats port
                # (15020) on each one.
                job_name        = "ztunnel"
                scrape_interval = "30s"
                kubernetes_sd_configs = [{
                  role       = "pod"
                  namespaces = { names = ["istio-system"] }
                }]
                relabel_configs = [
                  {
                    source_labels = ["__meta_kubernetes_pod_label_app"]
                    action        = "keep"
                    regex         = "ztunnel"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_container_port_name"]
                    action        = "keep"
                    regex         = "ztunnel-stats"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_node_name"]
                    target_label  = "node"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_name"]
                    target_label  = "pod"
                  },
                ]
              },
              {
                job_name        = "dcgm-exporter"
                scrape_interval = "30s"
                static_configs = [{
                  targets = ["dcgm-exporter.${module.namespace["system"].name}.svc.cluster.local:9400"]
                }]
              },
              {
                job_name        = "node-exporter"
                scrape_interval = "30s"
                kubernetes_sd_configs = [{
                  role       = "endpoints"
                  namespaces = { names = [module.namespace["system"].name] }
                }]
                relabel_configs = [
                  {
                    source_labels = ["__meta_kubernetes_service_name"]
                    action        = "keep"
                    regex         = local.node_exporter_name
                  },
                  {
                    source_labels = ["__meta_kubernetes_endpoint_port_name"]
                    action        = "keep"
                    regex         = "metrics"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_node_name"]
                    target_label  = "node"
                  },
                ]
              },
              {
                job_name        = "kube-state-metrics"
                scrape_interval = "30s"
                static_configs = [{
                  targets = ["${local.kube_state_metrics_name}.${module.namespace["system"].name}.svc.cluster.local:${local.kube_state_metrics_port}"]
                }]
              },
              {
                # Tetragon agent is a DaemonSet behind a Service. Scrape
                # endpoints directly so every node agent is represented rather
                # than one load-balanced service target.
                job_name        = "tetragon"
                scrape_interval = "30s"
                kubernetes_sd_configs = [{
                  role       = "endpoints"
                  namespaces = { names = [local.tetragon_namespace] }
                }]
                relabel_configs = [
                  {
                    source_labels = ["__meta_kubernetes_service_name"]
                    action        = "keep"
                    regex         = "tetragon"
                  },
                  {
                    source_labels = ["__meta_kubernetes_endpoint_port_name"]
                    action        = "keep"
                    regex         = "metrics"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_node_name"]
                    target_label  = "node"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_name"]
                    target_label  = "pod"
                  },
                ]
              },
              {
                job_name        = "tetragon-operator"
                scrape_interval = "30s"
                static_configs = [{
                  targets = ["tetragon-operator-metrics.${local.tetragon_namespace}.svc.cluster.local:2113"]
                }]
              },
              {
                job_name        = "trivy-operator"
                scrape_interval = "30s"
                static_configs = [{
                  targets = ["trivy-operator.${local.trivy_operator_namespace}.svc.cluster.local:80"]
                }]
              },
              {
                job_name        = "policy-reporter"
                scrape_interval = "30s"
                static_configs = [{
                  targets = ["policy-reporter.${local.policy_reporter_namespace}.svc.cluster.local:8080"]
                }]
              },
              {
                # Kepler is a DaemonSet; scrape each endpoint to preserve
                # per-node energy metrics instead of sampling one Service VIP.
                job_name        = "kepler"
                scrape_interval = "30s"
                kubernetes_sd_configs = [{
                  role       = "endpoints"
                  namespaces = { names = [local.kepler_namespace] }
                }]
                relabel_configs = [
                  {
                    source_labels = ["__meta_kubernetes_service_name"]
                    action        = "keep"
                    regex         = "kepler"
                  },
                  {
                    source_labels = ["__meta_kubernetes_endpoint_port_name"]
                    action        = "keep"
                    regex         = "http"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_node_name"]
                    target_label  = "node"
                  },
                  {
                    source_labels = ["__meta_kubernetes_pod_name"]
                    target_label  = "pod"
                  },
                ]
              },
              {
                job_name        = "nut_exporter"
                scrape_interval = "30s"
                metrics_path    = "/ups_metrics"
                params          = { ups = ["ups"] }
                static_configs = [{
                  targets = ["${kubernetes_service_v1.ups_management.metadata[0].name}.${local.ups_namespace}.svc.cluster.local:${local.ups_exporter_port}"]
                }]
              },
              {
                job_name        = "qbittorrent-exporter"
                scrape_interval = "30s"
                kubernetes_sd_configs = [{
                  role       = "endpoints"
                  namespaces = { names = [local.qbittorrent_ns] }
                }]
                relabel_configs = [
                  {
                    source_labels = ["__meta_kubernetes_service_name"]
                    action        = "keep"
                    regex         = "qbittorrent-exporter"
                  },
                  {
                    source_labels = ["__meta_kubernetes_endpoint_port_name"]
                    action        = "keep"
                    regex         = "metrics"
                  },
                ]
              },
            ]
          }
        }
      }
      processors = local.otel_processors
      exporters  = local.otel_exporters
      service = {
        telemetry = { logs = { level = "warn" } }
        pipelines = {
          logs    = { receivers = ["k8sobjects"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
          metrics = { receivers = ["k8s_cluster", "prometheus"], processors = local.otel_processor_chain, exporters = ["otlphttp"] }
        }
      }
    }

    resources = local.otel_resources
    ports     = { otlp = { enabled = false }, otlp-http = { enabled = false } }
  })]
}
