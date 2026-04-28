# =============================================================================
# Ceph CSI CephFS Driver
# =============================================================================
# Provides RWX (ReadWriteMany) volumes for workloads where multiple pods
# legitimately share a filesystem (e.g. Nextcloud's web/cron/worker tier).
# RBD remains the default for single-writer workloads (databases, etc).

locals {
  cephfs_name             = "cephfs"
  cephfs_subvolume_group  = "csi"
}

# CephFS CSI lives in its own namespace so its Helm-managed ceph-config
# ConfigMap doesn't collide with the RBD driver's release in `system`.
resource "kubernetes_namespace_v1" "ceph_csi_fs" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "ceph-csi-cephfs"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "kubernetes_secret_v1" "ceph_csi_fs" {
  depends_on = [kubernetes_namespace_v1.ceph_csi_fs]

  metadata {
    name      = "csi-cephfs-secret"
    namespace = kubernetes_namespace_v1.ceph_csi_fs.metadata[0].name
  }

  data = {
    adminID  = "admin"
    adminKey = local.ceph_admin_key
  }
}

resource "helm_release" "ceph_csi_fs" {
  depends_on = [kubernetes_namespace_v1.ceph_csi_fs]

  name       = "ceph-csi-cephfs"
  repository = "https://ceph.github.io/csi-charts"
  chart      = "ceph-csi-cephfs"
  namespace  = kubernetes_namespace_v1.ceph_csi_fs.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    csiConfig = [{
      clusterID = local.ceph_fsid
      monitors  = local.ceph_monitors
    }]

    storageClass = { create = false }

    # Kyverno's `require-requests-for-arm-pool` policy rejects pods scheduled
    # onto Pi nodes that don't set CPU + memory requests on every container.
    # Set modest requests on every nodeplugin + provisioner container so the
    # DaemonSet schedules cluster-wide.
    nodeplugin = {
      registrar = { resources = { requests = { cpu = "10m", memory = "32Mi" } } }
      plugin    = { resources = { requests = { cpu = "50m", memory = "128Mi" } } }
    }
    provisioner = {
      replicaCount = 1
      provisioner = { resources = { requests = { cpu = "10m", memory = "64Mi" } } }
      attacher    = { resources = { requests = { cpu = "10m", memory = "64Mi" } } }
      resizer     = { resources = { requests = { cpu = "10m", memory = "64Mi" } } }
      snapshotter = { resources = { requests = { cpu = "10m", memory = "64Mi" } } }
    }
  })]
}

resource "kubernetes_storage_class_v1" "cephfs" {
  depends_on = [helm_release.ceph_csi_fs, kubernetes_secret_v1.ceph_csi_fs]

  metadata {
    name = "cephfs"
  }

  storage_provisioner    = "cephfs.csi.ceph.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"

  parameters = {
    clusterID        = local.ceph_fsid
    fsName           = local.cephfs_name
    subvolumeGroup   = local.cephfs_subvolume_group

    # Talos kernels don't ship the `ceph` kmod, so kernel mount.ceph fails with
    # "Module ceph not found". Use ceph-fuse instead — userspace, no kmod
    # required, lives inside the cephcsi container image.
    mounter = "fuse"

    "csi.storage.k8s.io/provisioner-secret-name"            = kubernetes_secret_v1.ceph_csi_fs.metadata[0].name
    "csi.storage.k8s.io/provisioner-secret-namespace"       = kubernetes_namespace_v1.ceph_csi_fs.metadata[0].name
    "csi.storage.k8s.io/controller-expand-secret-name"      = kubernetes_secret_v1.ceph_csi_fs.metadata[0].name
    "csi.storage.k8s.io/controller-expand-secret-namespace" = kubernetes_namespace_v1.ceph_csi_fs.metadata[0].name
    "csi.storage.k8s.io/node-stage-secret-name"             = kubernetes_secret_v1.ceph_csi_fs.metadata[0].name
    "csi.storage.k8s.io/node-stage-secret-namespace"        = kubernetes_namespace_v1.ceph_csi_fs.metadata[0].name
  }
}
