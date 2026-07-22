# =============================================================================
# CSI Volume Snapshots
# =============================================================================
# External snapshotter CRDs/controller plus a small label-driven scheduler for
# crash-consistent RBD snapshots. CNPG instance PVCs are intentionally excluded;
# PostgreSQL restores must use Barman bootstrap.recovery.
#
# The scheduler job runs a Ceph-safety preflight (Jul 3-4 2026: the first full
# snapshot pass stalled neo's NVMe controllers and aborted both of its OSDs)
# and verifies each created snapshot reaches readyToUse, so a wedged storage
# pipeline fails the job loudly instead of silently piling on load.

locals {
  external_snapshotter_version     = "v8.2.0"
  volume_snapshot_scheduler_script = <<-EOT
    #!/bin/sh
    set -eu

    tier="$${SNAPSHOT_TIER:?SNAPSHOT_TIER is required}"
    class="$${SNAPSHOT_CLASS:-ceph-rbd}"
    stamp="$(date -u +%Y%m%d%H%M%S)"
    created=/tmp/created-snapshots.txt
    : > "$${created}"

    # ---- Preflight ---------------------------------------------------------
    # Refuse to add snapshot load to an unhealthy storage pipeline; a failing
    # job here is the canary.

    # 1. Snapshot controller must be available.
    kubectl -n kube-system wait deployment/snapshot-controller \
      --for=condition=Available --timeout=120s

    # 2. Any scheduled snapshot from a PREVIOUS run still not ready means the
    #    CSI/Ceph pipeline is wedged (this run's names carry a fresh stamp, so
    #    everything matched here is at least one schedule-period old).
    stuck="$(kubectl get volumesnapshot -A -l 'aether.shdr.ch/snapshot-schedule' \
      -o go-template='{{range .items}}{{if not .status}}{{.metadata.namespace}}/{{.metadata.name}}{{"\n"}}{{else if not .status.readyToUse}}{{.metadata.namespace}}/{{.metadata.name}}{{"\n"}}{{end}}{{end}}')"
    if [ -n "$${stuck}" ]; then
      echo "PREFLIGHT FAILED: snapshots from previous runs are not ready:" >&2
      echo "$${stuck}" >&2
      echo "Storage pipeline may be unhealthy (check 'ceph -s' and OSD/kernel logs on the PVE hosts); aborting." >&2
      exit 1
    fi

    # ---- Create --------------------------------------------------------------
    for ns in $(kubectl get ns -l "aether.shdr.ch/backup=$${tier}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
      kubectl get pvc -n "$${ns}" -l '!cnpg.io/cluster' -o go-template='{{range .items}}{{if eq .spec.storageClassName "ceph-rbd"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' |
      while IFS= read -r pvc; do
        [ -n "$${pvc}" ] || continue
        short="$(printf '%s' "$${pvc}" | cut -c1-26)"
        hash="$(printf '%s' "$${pvc}" | cksum | cut -d ' ' -f1)"
        snapshot="$${short}-$${hash}-$${tier}-$${stamp}"
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
        echo "$${ns} $${snapshot}" >> "$${created}"
      done
    done

    # ---- Verify --------------------------------------------------------------
    # RBD snapshots become ready in seconds when Ceph is healthy. Waiting with a
    # timeout makes this job FAIL loudly instead of leaving wedged snapshots for
    # the next run's preflight to trip over.
    rc=0
    while read -r ns name; do
      [ -n "$${ns}" ] || continue
      if ! kubectl -n "$${ns}" wait "volumesnapshot/$${name}" \
          --for=jsonpath='{.status.readyToUse}'=true --timeout=180s; then
        echo "TIMEOUT waiting for $${ns}/$${name} to become ready" >&2
        rc=1
      fi
    done < "$${created}"
    exit "$${rc}"
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
      clusterID                                         = local.ceph_fsid
      "csi.storage.k8s.io/snapshotter-secret-name"      = kubernetes_secret_v1.ceph_csi.metadata[0].name
      "csi.storage.k8s.io/snapshotter-secret-namespace" = module.namespace["system"].name
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

  # kubectl wait deployment/snapshot-controller (preflight #1) needs get+watch.
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch"]
  }

  # get/list for the stuck-snapshot preflight, get+watch for the readyToUse
  # verify wait, create for the snapshots themselves.
  rule {
    api_groups = ["snapshot.storage.k8s.io"]
    resources  = ["volumesnapshots"]
    verbs      = ["create", "get", "list", "watch"]
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
        # Bound retries/runtime: a failed preflight or verify must surface as
        # a failed Job (alertable), not retry-spam the storage pipeline.
        backoff_limit           = 1
        active_deadline_seconds = 1800

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
              image   = "docker.io/alpine/k8s:1.33.2"
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
