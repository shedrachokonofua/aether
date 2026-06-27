# =============================================================================
# Security and Efficiency Observability
# =============================================================================
# These components are report/observe-only. They do not mutate workloads, block
# admission, or enforce runtime policy.

locals {
  tetragon_namespace        = "tetragon"
  trivy_operator_namespace  = "trivy-system"
  policy_reporter_namespace = "policy-reporter"
  kepler_namespace          = "kepler"
  node_agent_priority_class = "aether-node-agent"

  policy_reporter_host = "policy-reporter.home.shdr.ch"

  trivy_scan_job_affinity = {
    nodeAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 90
        preference = {
          matchExpressions = [{
            key      = "kubernetes.io/arch"
            operator = "In"
            values   = ["amd64"]
          }]
        }
      }]
    }
  }

  trivy_scan_job_container_security_context = {
    allowPrivilegeEscalation = false
    capabilities = {
      drop = ["ALL"]
    }
    privileged             = false
    readOnlyRootFilesystem = false
  }

  trivy_node_collector_volumes = [
    {
      name = "var-lib-kubelet"
      hostPath = {
        path = "/var/lib/kubelet"
      }
    },
    {
      name = "etc-kubernetes"
      hostPath = {
        path = "/etc/kubernetes"
      }
    },
    {
      name = "etc-cni-netd"
      hostPath = {
        path = "/etc/cni/net.d/"
      }
    },
  ]

  trivy_node_collector_volume_mounts = [
    {
      name      = "var-lib-kubelet"
      mountPath = "/var/lib/kubelet"
      readOnly  = true
    },
    {
      name      = "etc-kubernetes"
      mountPath = "/etc/kubernetes"
      readOnly  = true
    },
    {
      name      = "etc-cni-netd"
      mountPath = "/etc/cni/net.d/"
      readOnly  = true
    },
  ]

  trivy_scan_job_config_sha = sha256(jsonencode({
    affinity                  = local.trivy_scan_job_affinity
    containerSecurityContext  = local.trivy_scan_job_container_security_context
    nodeCollectorVolumeMounts = local.trivy_node_collector_volume_mounts
    nodeCollectorVolumes      = local.trivy_node_collector_volumes
    trivyScannerResourceHints = "25m-1Mi"
  }))
}

resource "kubernetes_priority_class_v1" "node_agent" {
  metadata {
    name = local.node_agent_priority_class
  }

  value             = 100000000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Node-level observability agents that must land before ordinary workloads."
}

# Tetragon needs privileged host access for eBPF runtime visibility.
resource "kubernetes_namespace_v1" "tetragon" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.tetragon_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "helm_release" "tetragon" {
  depends_on = [
    kubernetes_namespace_v1.tetragon,
    kubernetes_priority_class_v1.node_agent,
  ]

  name       = "tetragon"
  repository = "https://helm.cilium.io"
  chart      = "tetragon"
  namespace  = kubernetes_namespace_v1.tetragon.metadata[0].name
  version    = "1.7.0"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    priorityClassName = local.node_agent_priority_class

    tetragon = {
      clusterName       = var.cluster_name
      enableProcessCred = true
      enableProcessNs   = true
      exportRateLimit   = 1200
      exportFilePerm    = "640"
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
      prometheus = {
        enabled            = true
        metricsLabelFilter = "namespace,workload,pod,binary"
      }
    }

    tetragonOperator = {
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }
    }

    export = {
      mode = "stdout"
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }
  })]
}

resource "kubernetes_namespace_v1" "trivy_operator" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.trivy_operator_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "helm_release" "trivy_operator" {
  depends_on = [kubernetes_namespace_v1.trivy_operator]

  name       = "trivy-operator"
  repository = "https://aquasecurity.github.io/helm-charts/"
  chart      = "trivy-operator"
  namespace  = kubernetes_namespace_v1.trivy_operator.metadata[0].name
  version    = "0.33.1"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    operator = {
      scanJobTTL                                   = "1h"
      scanSecretTTL                                = "1h"
      scanJobTimeout                               = "10m"
      scanJobsConcurrentLimit                      = 4
      scanNodeCollectorLimit                       = 1
      scannerReportTTL                             = "168h"
      vulnerabilityScannerEnabled                  = true
      configAuditScannerEnabled                    = true
      rbacAssessmentScannerEnabled                 = true
      infraAssessmentScannerEnabled                = true
      clusterComplianceEnabled                     = true
      exposedSecretScannerEnabled                  = true
      vulnerabilityScannerScanOnlyCurrentRevisions = true
      configAuditScannerScanOnlyCurrentRevisions   = true
    }

    podAnnotations = {
      "aether.shdr.ch/scan-job-config-sha" = local.trivy_scan_job_config_sha
    }

    trivyOperator = {
      scanJobAffinity                            = local.trivy_scan_job_affinity
      scanJobPodTemplateContainerSecurityContext = local.trivy_scan_job_container_security_context
    }

    nodeCollector = {
      volumes      = local.trivy_node_collector_volumes
      volumeMounts = local.trivy_node_collector_volume_mounts
    }

    service = {
      headless = false
    }

    # Operator runs 6 scanner types over ~244 reports with 4 concurrent scan
    # jobs; at a 500m CPU limit it throttled hard and its 1s /healthz/ probe
    # stalled, triggering liveness kills (200+ restarts). Give it real headroom.
    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { cpu = "1", memory = "1Gi" }
    }

    trivy = {
      slow          = true
      ignoreUnfixed = false
      timeout       = "10m0s"
      severity      = "UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"
      resources = {
        requests = { cpu = "25m", memory = "1Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]
}

resource "kubernetes_namespace_v1" "policy_reporter" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.policy_reporter_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "helm_release" "policy_reporter" {
  depends_on = [
    kubernetes_namespace_v1.policy_reporter,
    helm_release.kyverno,
    helm_release.trivy_operator,
  ]

  name       = "policy-reporter"
  repository = "https://kyverno.github.io/policy-reporter"
  chart      = "policy-reporter"
  namespace  = kubernetes_namespace_v1.policy_reporter.metadata[0].name
  version    = "3.7.4"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    rest    = { enabled = true }
    metrics = { enabled = true }

    # Core REST API holds the policy/result set in memory; with ~244 trivy
    # VulnerabilityReports it sat at ~239Mi against a 256Mi limit and OOMed,
    # which made /v2/policies time out and crashlooped the trivy plugin probe.
    resources = {
      requests = { cpu = "50m", memory = "256Mi" }
      limits   = { cpu = "250m", memory = "512Mi" }
    }

    ui = {
      enabled = true
      name    = var.cluster_name
      service = {
        type = "ClusterIP"
        port = 8080
      }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }
    }

    plugin = {
      kyverno = {
        enabled = true
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
      trivy = {
        enabled = true

        # Without a GitHub PAT the plugin enriches findings via api.github.com
        # unauthenticated (60 req/h) and gets 403/429 rate limited, spamming
        # errors and loading the API. Disable that enrichment until a token is
        # available. To re-enable: add a read-only PAT to SOPS and set
        #   github = { token = var.secrets["github_pat"] }
        github = {
          disable = true
        }

        # Default liveness/readiness hit /vulnr/v1/policies (which proxies to
        # policy-reporter core) with a 3s timeout; transient core latency made
        # the probe flap and crashloop the pod (1800+ restarts). Relax timeout
        # and failureThreshold so brief core slowness is tolerated.
        livenessProbe = {
          httpGet             = { path = "/vulnr/v1/policies", port = "http" }
          initialDelaySeconds = 15
          periodSeconds       = 20
          timeoutSeconds      = 10
          failureThreshold    = 6
        }
        readinessProbe = {
          httpGet             = { path = "/vulnr/v1/policies", port = "http" }
          initialDelaySeconds = 10
          periodSeconds       = 20
          timeoutSeconds      = 10
          failureThreshold    = 6
        }

        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
    }
  })]
}

resource "helm_release" "trivy_operator_polr_adapter" {
  depends_on = [
    helm_release.policy_reporter,
    helm_release.trivy_operator,
  ]

  name       = "trivy-operator-polr-adapter"
  repository = "https://fjogeleit.github.io/trivy-operator-polr-adapter"
  chart      = "trivy-operator-polr-adapter"
  namespace  = kubernetes_namespace_v1.policy_reporter.metadata[0].name
  version    = "0.11.3"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    crds = {
      install = false
    }

    openreports = {
      enabled = false
      install = false
    }

    adapters = {
      vulnerabilityReports = {
        enabled = true
        timeout = 2
      }
      clusterVulnerabilityReports = {
        enabled = true
        timeout = 2
      }
      configAuditReports = {
        enabled = false
      }
      cisKubeBenchReports = {
        enabled = false
      }
      complianceReports = {
        enabled = false
      }
      rbacAssessmentReports = {
        enabled = false
      }
      exposedSecretReports = {
        enabled = false
      }
      infraAssessmentReports = {
        enabled = false
      }
      clusterInfraAssessmentReports = {
        enabled = false
      }
    }

    resources = {
      requests = { cpu = "25m", memory = "64Mi" }
      limits   = { cpu = "250m", memory = "256Mi" }
    }
  })]
}

resource "kubernetes_cluster_role_v1" "policy_reporter_trivy_plugin" {
  metadata {
    name = "policy-reporter-trivy-plugin"
  }

  rule {
    api_groups = ["aquasecurity.github.io"]
    resources = [
      "clustercompliancereports",
      "clusterconfigauditreports",
      "clusterinfraassessmentreports",
      "clusterrbacassessmentreports",
      "clustersbomreports",
      "clustervulnerabilityreports",
      "configauditreports",
      "exposedsecretreports",
      "infraassessmentreports",
      "rbacassessmentreports",
      "sbomreports",
      "vulnerabilityreports",
    ]
    verbs = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "policy_reporter_trivy_plugin" {
  depends_on = [helm_release.policy_reporter]

  metadata {
    name = "policy-reporter-trivy-plugin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.policy_reporter_trivy_plugin.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "policy-reporter-trivy-plugin"
    namespace = kubernetes_namespace_v1.policy_reporter.metadata[0].name
  }
}

resource "kubernetes_manifest" "policy_reporter_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.policy_reporter]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "policy-reporter"
      namespace = kubernetes_namespace_v1.policy_reporter.metadata[0].name
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.policy_reporter_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "policy-reporter-ui"
          port = 8080
        }]
      }]
    }
  }
}

# Kepler uses eBPF and host counters for node/pod energy metrics.
resource "kubernetes_namespace_v1" "kepler" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.kepler_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "helm_release" "kepler" {
  depends_on = [kubernetes_namespace_v1.kepler]

  name       = "kepler"
  repository = "https://sustainable-computing-io.github.io/kepler-helm-chart"
  chart      = "kepler"
  namespace  = kubernetes_namespace_v1.kepler.metadata[0].name
  version    = "0.6.1"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    image = {
      pullPolicy = "IfNotPresent"
    }

    canMount = {
      usrSrc = false
    }

    extraEnvVars = {
      KEPLER_LOG_LEVEL           = "1"
      ENABLE_GPU                 = "true"
      ENABLE_QAT                 = "false"
      ENABLE_EBPF_CGROUPID       = "true"
      EXPOSE_HW_COUNTER_METRICS  = "true"
      EXPOSE_IRQ_COUNTER_METRICS = "true"
      EXPOSE_CGROUP_METRICS      = "true"
      ENABLE_PROCESS_METRICS     = "false"
      CGROUP_METRICS             = "*"
    }

    resources = {
      requests = { cpu = "25m", memory = "16Mi" }
      limits   = { cpu = "1", memory = "512Mi" }
    }

    service = {
      type = "ClusterIP"
      port = 9102
    }

    serviceMonitor = {
      enabled = false
    }

    modelServer = {
      enabled = false
    }
  })]
}
