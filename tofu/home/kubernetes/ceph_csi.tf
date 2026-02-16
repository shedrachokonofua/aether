# =============================================================================
# Ceph CSI Driver for Kubernetes
# =============================================================================
# Enables dynamic provisioning of Ceph RBD volumes.

locals {
  # Use explicit v2 msgr addresses (port 3300) for modern Ceph (Squid/19+)
  ceph_monitors  = ["192.168.2.202:3300", "192.168.2.204:3300", "192.168.2.205:3300"]
  ceph_pool      = "kubernetes"
  ceph_fsid      = var.secrets["ceph.fsid"]
  ceph_admin_key = var.secrets["ceph.admin_key"]
}

# =============================================================================
# Namespace for platform components
# =============================================================================

resource "kubernetes_namespace_v1" "system" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# =============================================================================
# Ceph Credentials Secret
# =============================================================================

resource "kubernetes_secret_v1" "ceph_csi" {
  depends_on = [kubernetes_namespace_v1.system]

  metadata {
    name      = "csi-rbd-secret"
    namespace = kubernetes_namespace_v1.system.metadata[0].name
  }

  data = {
    userID  = "admin"
    userKey = local.ceph_admin_key
  }
}

# =============================================================================
# Ceph CSI RBD Driver (Helm)
# =============================================================================

resource "helm_release" "ceph_csi_rbd" {
  depends_on = [kubernetes_namespace_v1.system]

  name       = "ceph-csi-rbd"
  repository = "https://ceph.github.io/csi-charts"
  chart      = "ceph-csi-rbd"
  namespace  = kubernetes_namespace_v1.system.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    csiConfig = [{
      clusterID = local.ceph_fsid
      monitors  = local.ceph_monitors
    }]

    provisioner  = { replicaCount = 1 }
    storageClass = { create = false }
  })]
}

# =============================================================================
# StorageClass for Ceph RBD
# =============================================================================

resource "kubernetes_storage_class_v1" "ceph_rbd" {
  depends_on = [helm_release.ceph_csi_rbd, kubernetes_secret_v1.ceph_csi]

  metadata {
    name = "ceph-rbd"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "rbd.csi.ceph.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"

  mount_options = ["discard"]

  parameters = {
    clusterID     = local.ceph_fsid
    pool          = local.ceph_pool
    imageFeatures = "layering"

    "csi.storage.k8s.io/provisioner-secret-name"            = kubernetes_secret_v1.ceph_csi.metadata[0].name
    "csi.storage.k8s.io/provisioner-secret-namespace"       = kubernetes_namespace_v1.system.metadata[0].name
    "csi.storage.k8s.io/controller-expand-secret-name"      = kubernetes_secret_v1.ceph_csi.metadata[0].name
    "csi.storage.k8s.io/controller-expand-secret-namespace" = kubernetes_namespace_v1.system.metadata[0].name
    "csi.storage.k8s.io/node-stage-secret-name"             = kubernetes_secret_v1.ceph_csi.metadata[0].name
    "csi.storage.k8s.io/node-stage-secret-namespace"        = kubernetes_namespace_v1.system.metadata[0].name
  }
}
