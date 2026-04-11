# =============================================================================
# NFS CSI Driver for Kubernetes
# =============================================================================
# Enables dynamic and static NFS volume provisioning.
# Used for media storage (hdd data from NFS LXC on smith).

resource "helm_release" "csi_driver_nfs" {
  depends_on = [kubernetes_namespace_v1.system]

  name       = "csi-driver-nfs"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  namespace  = kubernetes_namespace_v1.system.metadata[0].name
  wait       = true
  timeout    = 300
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
