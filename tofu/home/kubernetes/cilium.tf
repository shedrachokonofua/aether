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
  version          = "1.17.0"
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

    # Hubble observability
    hubble = {
      enabled = true
      relay   = { enabled = true }
      ui      = { enabled = true }
    }

    # Gateway API support
    gatewayAPI = { enabled = true }

    # IPAM mode
    ipam = { mode = "kubernetes" }

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
      interfaces      = ["^ens[0-9]+"]
      externalIPs     = true
      loadBalancerIPs = true
    }
  }
}

# LoadBalancer IP Pool - single VIP for all LoadBalancer services
resource "kubernetes_manifest" "cilium_ip_pool" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
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
