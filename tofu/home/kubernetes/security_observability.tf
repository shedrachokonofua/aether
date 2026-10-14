# =============================================================================
# Security and Efficiency Observability
# =============================================================================
# These components are report/observe-only. They do not mutate workloads, block
# admission, or enforce runtime policy.

locals {
  tetragon_namespace        = "tetragon"
  trivy_operator_namespace  = "trivy-system"
  node_agent_priority_class = "aether-node-agent"

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
    containerSecurityContext  = local.trivy_scan_job_container_security_context
    nodeCollectorVolumeMounts = local.trivy_node_collector_volume_mounts
    nodeCollectorVolumes      = local.trivy_node_collector_volumes
    trivyMode                 = "ClientServer"
    trivyScanPodTmpSubpaths   = true
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

resource "helm_release" "tetragon" {
  depends_on = [
    module.namespace["tetragon"],
    kubernetes_priority_class_v1.node_agent,
  ]

  name       = "tetragon"
  repository = "https://helm.cilium.io"
  chart      = "tetragon"
  namespace  = module.namespace["tetragon"].name
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
      # 30d: ARM-pool p95 268Mi, fleet max 563Mi, ARM-pool CPU p50 18m.
      resources = {
        requests = { cpu = "20m", memory = "272Mi" }
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


resource "helm_release" "trivy_operator" {
  depends_on = [module.namespace["trivy-system"]]

  name       = "trivy-operator"
  repository = "https://aquasecurity.github.io/helm-charts/"
  chart      = "trivy-operator"
  namespace  = module.namespace["trivy-system"].name
  version    = "0.33.1"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    operator = {
      replicas                = 1
      scanJobTTL              = "1h"
      scanSecretTTL           = "1h"
      scanJobTimeout          = "10m"
      scanJobsConcurrentLimit = 4
      scanNodeCollectorLimit  = 1
      builtInTrivyServer      = true
      # The 2026-07-31 incident showed that 168h retained a full week of report
      # churn in etcd; 24h is enough because Grafana/Prometheus retain findings
      # history and reports regenerate on the scan schedule.
      scannerReportTTL                             = "24h"
      vulnerabilityScannerEnabled                  = true
      configAuditScannerEnabled                    = true
      rbacAssessmentScannerEnabled                 = true
      infraAssessmentScannerEnabled                = true
      clusterComplianceEnabled                     = true
      exposedSecretScannerEnabled                  = true
      vulnerabilityScannerScanOnlyCurrentRevisions = true
      configAuditScannerScanOnlyCurrentRevisions   = true
      # Per-CVE metric (trivy_vulnerability_id) with fixed-version label so the
      # critical-vulns alert can count only actionable (fixable) findings.
      # Cardinality cost is bounded: local Prometheus, ~250 reports.
      metricsVulnIdEnabled = true
    }

    podAnnotations = {
      "aether.shdr.ch/scan-job-config-sha" = local.trivy_scan_job_config_sha
    }

    trivyOperator = {
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
    # stalled, triggering liveness kills (200+ restarts).
    # On 2026-09-14T00:27:45Z it was OOMKilled at the 2Gi limit; cAdvisor's
    # 48h peak was 2,142,879,744 bytes, so 4Gi provides at least 1.5x headroom.
    # Report updates also hit the 2MiB gRPC object limit (2,817,615 bytes at
    # 2026-09-13T23:18:38Z; 2,153,734 bytes at 2026-09-14T00:07:50Z) while
    # all severities were retained.
    resources = {
      requests = { cpu = "100m", memory = "2Gi" }
      limits   = { cpu = "1", memory = "4Gi" }
    }

    trivy = {
      mode                   = "ClientServer"
      clientServerSkipUpdate = true
      storageClassName       = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
      storageSize            = "5Gi"
      priorityClassName      = local.node_agent_priority_class
      slow                   = true
      ignoreUnfixed          = false
      timeout                = "10m0s"
      severity               = "CRITICAL,HIGH"
      resources = {
        requests = { cpu = "25m", memory = "1Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]
}

