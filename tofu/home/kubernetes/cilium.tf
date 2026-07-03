# =============================================================================
# Cilium CNI
# =============================================================================
# CNI with kube-proxy replacement, L2 announcements, and Gateway API support

resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  namespace        = "kube-system"
  create_namespace = false
  version          = "1.19.2"
  wait             = true
  timeout          = 600

  values = [yamlencode({
    # Talos-specific: kube-proxy replacement
    kubeProxyReplacement = true
    k8sServiceHost       = var.api_vip
    k8sServicePort       = 6443

    # L2 announcements for LoadBalancer services
    l2announcements = { enabled = true }
    externalIPs     = { enabled = true }

    # Hubble observability — Prom-scrapeable L4 + L7 metrics with
    # source/destination workload labels. Lets us answer "is service X
    # active right now?" without per-app instrumentation.
    #
    # `httpV2` is the modern HTTP metric set; workload-name labels give us
    # `destination_workload="docling"` etc. `flow` covers L4.
    # `serviceMonitor` is off because the cluster scrapes via the in-cluster
    # OTel collector (see otel_collector.tf), not Prometheus Operator CRDs.
    hubble = {
      enabled = true
      relay   = { enabled = true }
      ui      = { enabled = true }
      metrics = {
        enableOpenMetrics = true
        enabled = [
          "drop",
          "tcp",
          "flow",
          "port-distribution",
          "icmp",
          "httpV2:exemplars=true;sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;labelsContext=source_namespace,destination_namespace",
        ]
        serviceMonitor = { enabled = false }
      }
    }

    # Gateway API support
    gatewayAPI = { enabled = true }

    # IPAM mode
    ipam = { mode = "kubernetes" }

    # Allow Istio CNI to chain (required for Istio Ambient)
    cni = { exclusive = false }

    # Operator replicas (single replica for small cluster)
    operator = { replicas = 1 }

    # Talos-specific: cgroup settings
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    # Talos-specific: explicit capabilities
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
  })]
}

# L2 Announcement Policy - enables ARP responses for LoadBalancer IPs
resource "kubernetes_manifest" "cilium_l2_policy" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata = {
      name = "cluster-ingress"
    }
    spec = {
      interfaces      = ["^ens[0-9]+", "^end[0-9]+"]
      externalIPs     = true
      loadBalancerIPs = true
    }
  }
}

# LoadBalancer IP Pool - single VIP for all LoadBalancer services
resource "kubernetes_manifest" "cilium_ip_pool" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata = {
      name = "ingress-pool"
    }
    spec = {
      blocks = [
        {
          start = var.workload_vip
          stop  = var.workload_vip
        },
        {
          start = var.vcluster_vip
          stop  = var.vcluster_vip
        },
        # game-server Moonlight VIP (reuses the decommissioned VM 1014 IP)
        {
          start = local.game_server_vip
          stop  = local.game_server_vip
        },
      ]
    }
  }
}

# =============================================================================
# Cilium NetworkPolicy baseline
# =============================================================================
# Cluster-wide allow rules used by later namespace default-deny flips. These
# rules deliberately do not enable default-deny by themselves; per-namespace
# CNPs opt endpoints into default-deny after canary observation.

resource "kubernetes_manifest" "cilium_cluster_baseline_network" {
  depends_on = [helm_release.cilium]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "aether-cluster-baseline"
    }
    spec = {
      endpointSelector = {}
      enableDefaultDeny = {
        ingress = false
        egress  = false
      }
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = "kube-system"
              "k8s-app"                     = "kube-dns"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "ANY" },
            ]
          }]
        },
        {
          toEntities = ["kube-apiserver"]
          toPorts = [{
            ports = [
              { port = "443", protocol = "TCP" },
              { port = "6443", protocol = "TCP" },
            ]
          }]
        },
      ]
    }
  }
}

# First default-deny canary. Miniflux is small, health-checked, and has a
# same-namespace CNPG backend; egress stays intentionally broad during the
# observation window so this step validates gateway/same-namespace ingress
# before tightening feed-fetch egress.
resource "kubernetes_manifest" "miniflux_cilium_network_canary" {
  depends_on = [
    helm_release.cilium,
    kubernetes_deployment_v1.miniflux,
    kubernetes_manifest.cilium_cluster_baseline_network,
  ]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "namespace-canary"
      namespace = local.miniflux_ns
    }
    spec = {
      endpointSelector = {}
      ingress = [
        {
          fromEntities = ["ingress"]
          toPorts = [{
            ports = [
              { port = tostring(local.miniflux_port), protocol = "TCP" },
            ]
          }]
        },
        {
          fromEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.miniflux_ns
            }
          }]
        },
        {
          fromEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = "system"
            }
          }]
        },
        {
          # CloudNativePG operator polls each instance manager on :8000; without
          # this, the default-deny canary leaves clusters healthy but unreconciled.
          fromEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.cnpg_namespace
            }
          }]
          toPorts = [{
            ports = [
              { port = "8000", protocol = "TCP" },
            ]
          }]
        },
      ]
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.miniflux_ns
            }
          }]
        },
        {
          toEntities = ["world"]
        },
        {
          toCIDR = ["10.0.2.2/32"]
          toPorts = [{
            ports = [
              { port = "443", protocol = "TCP" },
            ]
          }]
        },
      ]
    }
  }
}

# =============================================================================
# RBAC
# =============================================================================

# Map Keycloak 'admin' group to cluster-admin
resource "kubernetes_cluster_role_binding_v1" "oidc_admin" {
  metadata {
    name = "oidc-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "Group"
    name      = "admin"
    api_group = "rbac.authorization.k8s.io"
  }
}
