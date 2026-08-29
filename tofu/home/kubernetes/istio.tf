# =============================================================================
# Istio Ambient Mesh
# =============================================================================
# Sidecar-less L4 mTLS via ztunnel. Cilium remains CNI and Gateway controller.
# CA delegated to cert-manager via istio-csr → step-issuer → step-ca.
# Enrolled namespaces: vc-seven30 (labeled with istio.io/dataplane-mode=ambient)

locals {
  istio_version = "1.29.0"
}

# Namespace with privileged PodSecurity - required for istio-cni (hostPath, NET_ADMIN) and ztunnel

resource "helm_release" "istio_base" {
  depends_on = [module.namespace["istio-system"]]

  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  namespace        = "istio-system"
  create_namespace = false
  version          = local.istio_version
  wait             = true
  timeout          = 300
}

resource "helm_release" "istiod" {
  depends_on = [helm_release.istio_base, helm_release.istio_csr]

  name             = "istiod"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  namespace        = "istio-system"
  create_namespace = false
  version          = local.istio_version
  wait             = true
  timeout          = 300

  values = [yamlencode({
    profile = "ambient"
    pilot = {
      env = {
        ENABLE_CA_SERVER = "false"
      }
    }
    global = {
      caAddress = local.istio_csr_service
    }
  })]
}

resource "helm_release" "istio_cni" {
  depends_on = [helm_release.istiod]

  name             = "istio-cni"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "cni"
  namespace        = "istio-system"
  create_namespace = false
  version          = local.istio_version
  wait             = true
  timeout          = 300

  values = [yamlencode({
    profile    = "ambient"
    cniBinDir  = "/opt/cni/bin"
    cniConfDir = "/etc/cni/net.d"
    # 228Mi/node, 912Mi across the four-Pi pool; Kyverno arm-pool-guardrails
    # blocks ambient-namespace Pods from binding there.
    affinity = local.off_arm_pool
  })]
}

resource "helm_release" "ztunnel" {
  depends_on = [helm_release.istio_cni]

  name             = "ztunnel"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "ztunnel"
  namespace        = "istio-system"
  create_namespace = false
  version          = local.istio_version
  wait             = true
  timeout          = 300

  values = [yamlencode({
    caAddress = local.istio_csr_service
    # Chart 1.29.0 renders `.Values.affinity` although values.yaml does not document it.
    affinity = local.off_arm_pool
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { cpu = "1000m", memory = "512Mi" }
    }
  })]
}
