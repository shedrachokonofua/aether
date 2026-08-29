# =============================================================================
# NFS CSI Driver for Kubernetes
# =============================================================================
# Enables dynamic and static NFS volume provisioning.
# Used for media storage (hdd data from NFS LXC on smith).

resource "helm_release" "csi_driver_nfs" {
  depends_on = [module.namespace["system"]]

  name       = "csi-driver-nfs"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  namespace  = module.namespace["system"].name
  wait       = true
  # 900s, not chart default 300s: 8-node DaemonSet rollout takes ~50s per node, so 300s can expire mid-rollout and mark Helm failed despite converged pods.
  timeout = 900

  values = [yamlencode({
    node = {
      # 30d: ARM-pool p95 41Mi, fleet max 73Mi, ARM-pool CPU p50 10m.
      resources = {
        nfs = {
          requests = {
            cpu    = "10m"
            memory = "48Mi"
          }
        }
      }
    }
  })]
}

# =============================================================================
# StorageClass — NFS HDD (smith NFS LXC)
# =============================================================================
# Points at the existing /mnt/hdd/data export. 10.0.3.0/24 already allow-listed.

resource "kubernetes_storage_class_v1" "nfs_hdd" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "nfs-hdd"
  }

  storage_provisioner = "nfs.csi.k8s.io"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  mount_options = ["nfsvers=4.1", "hard", "nointr"]

  parameters = {
    server = var.nfs_server_ip
    share  = "/mnt/hdd/data"
  }
}
