# =============================================================================
# CSI Volume Snapshots
# =============================================================================
# External snapshotter CRDs/controller plus a small label-driven scheduler for
# crash-consistent RBD snapshots. CNPG instance PVCs are intentionally excluded;
# PostgreSQL restores must use Barman bootstrap.recovery.

locals {
  external_snapshotter_version     = "v8.2.0"
  volume_snapshot_scheduler_script = <<-EOT
    #!/bin/sh
    set -eu

    tier="$${SNAPSHOT_TIER:?SNAPSHOT_TIER is required}"
    class="$${SNAPSHOT_CLASS:-ceph-rbd}"
    stamp="$$(date -u +%Y%m%d%H%M%S)"

    for ns in $$(kubectl get ns -l "aether.shdr.ch/backup=$${tier}" -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do
      kubectl get pvc -n "$${ns}" -l '!cnpg.io/cluster' -o go-template='{{range .items}}{{if eq .spec.storageClassName "ceph-rbd"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' |
      while IFS= read -r pvc; do
        [ -n "$${pvc}" ] || continue
        short="$$(printf '%s' "$${pvc}" | cut -c1-36)"
        snapshot="$${short}-$${tier}-$${stamp}"
        cat <<EOF | kubectl create -n "$${ns}" -f -
    apiVersion: snapshot.storage.k8s.io/v1
    kind: VolumeSnapshot
    metadata:
      name: $${snapshot}
      labels:
        aether.shdr.ch/snapshot-schedule: $${tier}
        aether.shdr.ch/source-pvc: $${pvc}
    spec:
      volumeSnapshotClassName: $${class}
      source:
        persistentVolumeClaimName: $${pvc}
    EOF
      done
    done
  EOT
}

data "http" "external_snapshotter_crd_volumesnapshotclasses" {
  url = "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${local.external_snapshotter_version}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
}

data "http" "external_snapshotter_crd_volumesnapshotcontents" {
  url = "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${local.external_snapshotter_version}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
}

data "http" "external_snapshotter_crd_volumesnapshots" {
  url = "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${local.external_snapshotter_version}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml"
}

data "http" "external_snapshotter_controller_rbac" {
  url = "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${local.external_snapshotter_version}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
}

data "http" "external_snapshotter_controller_setup" {
  url = "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${local.external_snapshotter_version}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
}

data "kubectl_file_documents" "external_snapshotter_crds" {
  content = join("\n---\n", [
    data.http.external_snapshotter_crd_volumesnapshotclasses.response_body,
    data.http.external_snapshotter_crd_volumesnapshotcontents.response_body,
    data.http.external_snapshotter_crd_volumesnapshots.response_body,
  ])
}

data "kubectl_file_documents" "external_snapshotter_controller" {
  content = join("\n---\n", [
    data.http.external_snapshotter_controller_rbac.response_body,
    data.http.external_snapshotter_controller_setup.response_body,
  ])
}

resource "kubectl_manifest" "external_snapshotter_crds" {
  for_each = data.kubectl_file_documents.external_snapshotter_crds.manifests

  yaml_body         = each.value
  server_side_apply = true
}

resource "kubectl_manifest" "external_snapshotter_controller" {
  for_each = data.kubectl_file_documents.external_snapshotter_controller.manifests

  depends_on = [kubectl_manifest.external_snapshotter_crds]

  yaml_body         = each.value
  server_side_apply = true
}

resource "kubectl_manifest" "ceph_rbd_volume_snapshot_class" {
  depends_on = [
    kubectl_manifest.external_snapshotter_crds,
    helm_release.ceph_csi_rbd,
    kubernetes_secret_v1.ceph_csi,
  ]

  yaml_body = yamlencode({
    apiVersion = "snapshot.storage.k8s.io/v1"
    kind       = "VolumeSnapshotClass"
    metadata = {
      name = "ceph-rbd"
      labels = {
        "app.kubernetes.io/managed-by" = "tofu"
      }
    }
    driver         = kubernetes_storage_class_v1.ceph_rbd.storage_provisioner
    deletionPolicy = "Delete"
    parameters = {
      clusterID                                                = local.ceph_fsid
      "csi.storage.k8s.io/snapshotter-secret-name"             = kubernetes_secret_v1.ceph_csi.metadata[0].name
      "csi.storage.k8s.io/snapshotter-secret-namespace"        = module.namespace["system"].name
      "csi.storage.k8s.io/snapshotter-list-secret-name"        = kubernetes_secret_v1.ceph_csi.metadata[0].name
      "csi.storage.k8s.io/snapshotter-list-secret-namespace"   = module.namespace["system"].name
      "csi.storage.k8s.io/snapshotter-delete-secret-name"      = kubernetes_secret_v1.ceph_csi.metadata[0].name
      "csi.storage.k8s.io/snapshotter-delete-secret-namespace" = module.namespace["system"].name
    }
  })
}

resource "kubernetes_service_account_v1" "volume_snapshot_scheduler" {
  depends_on = [module.namespace["kube-system"]]

  metadata {
    name      = "volume-snapshot-scheduler"
    namespace = module.namespace["kube-system"].name
    labels = {
      "app.kubernetes.io/name"       = "volume-snapshot-scheduler"
      "app.kubernetes.io/managed-by" = "tofu"
    }
  }
}

resource "kubernetes_config_map_v1" "volume_snapshot_scheduler" {
  depends_on = [module.namespace["kube-system"]]

  metadata {
    name      = "volume-snapshot-scheduler"
    namespace = module.namespace["kube-system"].name
    labels = {
      "app.kubernetes.io/name"       = "volume-snapshot-scheduler"
      "app.kubernetes.io/managed-by" = "tofu"
    }
  }

  data = {
    "snapshot.sh" = local.volume_snapshot_scheduler_script
  }
}

resource "kubernetes_cluster_role_v1" "volume_snapshot_scheduler" {
  metadata {
    name = "volume-snapshot-scheduler"
    labels = {
      "app.kubernetes.io/name"       = "volume-snapshot-scheduler"
      "app.kubernetes.io/managed-by" = "tofu"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "persistentvolumeclaims"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["snapshot.storage.k8s.io"]
    resources  = ["volumesnapshots"]
    verbs      = ["create"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "volume_snapshot_scheduler" {
  metadata {
    name = "volume-snapshot-scheduler"
    labels = {
      "app.kubernetes.io/name"       = "volume-snapshot-scheduler"
      "app.kubernetes.io/managed-by" = "tofu"
    }
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.volume_snapshot_scheduler.metadata[0].name
    namespace = kubernetes_service_account_v1.volume_snapshot_scheduler.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.volume_snapshot_scheduler.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "volume_snapshot_scheduler" {
  for_each = {
    critical = "17 3 * * *"
    standard = "43 3 * * 0"
  }

  depends_on = [
    kubectl_manifest.ceph_rbd_volume_snapshot_class,
    kubectl_manifest.external_snapshotter_controller,
    kubernetes_cluster_role_binding_v1.volume_snapshot_scheduler,
    kubernetes_config_map_v1.volume_snapshot_scheduler,
  ]

  metadata {
    name      = "volume-snapshot-${each.key}"
    namespace = module.namespace["kube-system"].name
    labels = {
      "app.kubernetes.io/name"       = "volume-snapshot-scheduler"
      "app.kubernetes.io/managed-by" = "tofu"
      "aether.shdr.ch/backup"        = each.key
    }
  }

  spec {
    schedule                      = each.value
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "volume-snapshot-scheduler"
          "aether.shdr.ch/backup"  = each.key
        }
      }

      spec {
        template {
          metadata {
            labels = {
              "app.kubernetes.io/name" = "volume-snapshot-scheduler"
              "aether.shdr.ch/backup"  = each.key
            }
          }

          spec {
            service_account_name = kubernetes_service_account_v1.volume_snapshot_scheduler.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name    = "snapshot"
              image   = "registry.k8s.io/kubectl:v1.33.2"
              command = ["/bin/sh", "/scripts/snapshot.sh"]

              env {
                name  = "SNAPSHOT_TIER"
                value = each.key
              }

              env {
                name  = "SNAPSHOT_CLASS"
                value = "ceph-rbd"
              }

              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  cpu    = "100m"
                  memory = "128Mi"
                }
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.volume_snapshot_scheduler.metadata[0].name
                default_mode = "0555"
              }
            }
          }
        }
      }
    }
  }
}
