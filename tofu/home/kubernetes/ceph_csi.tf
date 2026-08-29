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


# =============================================================================
# Ceph Credentials Secret
# =============================================================================

resource "kubernetes_secret_v1" "ceph_csi" {
  depends_on = [module.namespace["system"]]

  metadata {
    name      = "csi-rbd-secret"
    namespace = module.namespace["system"].name
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
  depends_on = [module.namespace["system"]]

  name       = "ceph-csi-rbd"
  repository = "https://ceph.github.io/csi-charts"
  chart      = "ceph-csi-rbd"
  version    = "3.17.0"
  namespace  = module.namespace["system"].name
  wait       = true
  timeout    = 1200

  values = [yamlencode({
    csiConfig = [{
      clusterID = local.ceph_fsid
      monitors  = local.ceph_monitors
    }]

    # HostNetwork metrics mux also registers Go pprof (/debug/pprof). Nothing
    # scrapes csi_liveness — disable to close the node-IP disclosure surface.
    nodeplugin = {
      httpMetrics = { enabled = false }
      registrar = {
        # 30d: ARM-pool p95 12Mi, fleet max 28Mi, ARM-pool CPU p50 3m.
        resources = {
          requests = {
            cpu    = "10m"
            memory = "16Mi"
          }
        }
      }
      plugin = {
        # 30d: ARM-pool p95 78Mi, fleet max 194Mi, ARM-pool CPU p50 8m; chart 3.17.0
        # routes plugin, liveness and controller through one key, sized to largest (csi-rbdplugin, ARM p95 78Mi).
        resources = {
          requests = {
            cpu    = "10m"
            memory = "80Mi"
          }
        }
      }
    }

    provisioner = {
      replicaCount = 1
      provisioner = {
        # 30d: ARM-pool p95 36Mi, fleet max 80Mi, ARM-pool CPU p50 10m.
        resources = {
          requests = {
            cpu    = "10m"
            memory = "48Mi"
          }
        }
      }
      resizer = {
        # 30d: ARM-pool p95 33Mi, fleet max 81Mi, ARM-pool CPU p50 10m.
        resources = {
          requests = {
            cpu    = "10m"
            memory = "48Mi"
          }
        }
      }
      snapshotter = {
        # 30d: ARM-pool p95 29Mi, fleet max 85Mi, ARM-pool CPU p50 10m.
        resources = {
          requests = {
            cpu    = "10m"
            memory = "48Mi"
          }
        }
      }
      attacher = {
        # 30d: ARM-pool p95 23Mi, fleet max 66Mi, ARM-pool CPU p50 10m.
        resources = {
          requests = {
            cpu    = "10m"
            memory = "32Mi"
          }
        }
      }
    }

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
    "csi.storage.k8s.io/provisioner-secret-namespace"       = module.namespace["system"].name
    "csi.storage.k8s.io/controller-expand-secret-name"      = kubernetes_secret_v1.ceph_csi.metadata[0].name
    "csi.storage.k8s.io/controller-expand-secret-namespace" = module.namespace["system"].name
    "csi.storage.k8s.io/node-stage-secret-name"             = kubernetes_secret_v1.ceph_csi.metadata[0].name
    "csi.storage.k8s.io/node-stage-secret-namespace"        = module.namespace["system"].name
  }
}
