# =============================================================================
# CloudNativePG
# =============================================================================
# Operator foundation for the eventual per-app PostgreSQL migration.
# Existing app Postgres StatefulSets are not cut over here; migrations happen
# one database at a time after backup/restore proof.

locals {
  cnpg_namespace                  = "cnpg-system"
  cnpg_chart_version              = "0.29.1"
  cnpg_barman_cloud_chart_version = "0.8.1"
  cnpg_storage_class              = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

  # Shared Cluster spec knobs, referenced by every app Cluster.
  # Pooled clients keep connections open, so the 180s smart-shutdown default
  # stretched each primary restart to 2-6 min (2026-10-06); after 15s Postgres
  # falls back to fast shutdown. Not rendered into the pod spec, so changing it
  # restarts nothing (unlike stopDelay, which becomes the pod's
  # terminationGracePeriodSeconds).
  cnpg_smart_shutdown_timeout = 15
  # Rolling node upgrades: each single-instance primary has a PDB allowing 0
  # disruptions, which makes `talosctl upgrade`'s drain time out and abort.
  # Set true for the upgrade window, then back to false. On ceph-rbd a drained
  # primary restarts on another node with the same PVC.
  cnpg_node_maintenance = false
}


resource "helm_release" "cnpg" {
  depends_on = [
    module.namespace["cnpg-system"],
    kubernetes_storage_class_v1.ceph_rbd,
  ]

  name       = "cnpg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  namespace  = module.namespace["cnpg-system"].name
  version    = local.cnpg_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    crds = { create = true }

    # Swap the instance-manager binary in place on operator upgrades instead of
    # rolling every Cluster. All app Clusters are single-instance, so a rolling
    # update restarts each database. This does not cover pod-spec changes:
    # bumping plugin-barman-cloud changes its injected init-container image and
    # still restarts every Cluster's primary (observed on 0.7.0 -> 0.8.1).
    config = {
      data = {
        ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES = "true"
      }
    }

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }
  })]
}

resource "helm_release" "cnpg_barman_cloud" {
  depends_on = [
    helm_release.cert_manager,
    helm_release.cnpg,
  ]

  name       = "plugin-barman-cloud"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "plugin-barman-cloud"
  namespace  = module.namespace["cnpg-system"].name
  version    = local.cnpg_barman_cloud_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    crds = { create = true }

    # 30d p95 44Mi +20% (was 128Mi).
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "250m", memory = "256Mi" }
    }
  })]
}

resource "kubectl_manifest" "cnpg_kyverno_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:cnpg-cluster-read"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-admission-controller"  = "true"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
        "rbac.kyverno.io/aggregate-to-reports-controller"    = "true"
      }
    }
    rules = [{
      apiGroups = ["postgresql.cnpg.io"]
      resources = ["clusters"]
      verbs     = ["get", "list", "watch"]
    }]
  })
}

resource "kubectl_manifest" "cnpg_require_ceph_rbd_storage" {
  depends_on = [
    helm_release.cnpg,
    helm_release.kyverno,
    kubectl_manifest.cnpg_kyverno_rbac,
    kubernetes_storage_class_v1.ceph_rbd,
  ]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "cnpg-require-ceph-rbd-storage"
      annotations = {
        "policies.kyverno.io/title"       = "Require Ceph RBD for CloudNativePG"
        "policies.kyverno.io/category"    = "Storage"
        "policies.kyverno.io/subject"     = "CloudNativePG Cluster"
        "policies.kyverno.io/description" = "CloudNativePG clusters must place PGDATA and optional WAL PVCs on the Ceph RBD storage class."
      }
    }
    spec = {
      validationFailureAction = "Enforce"
      background              = true
      rules = [
        {
          name = "require-pgdata-ceph-rbd"
          match = {
            any = [{
              resources = {
                kinds = ["postgresql.cnpg.io/v1/Cluster"]
              }
            }]
          }
          validate = {
            message = "CloudNativePG PGDATA storage must explicitly use ceph-rbd."
            pattern = {
              spec = {
                storage = {
                  storageClass = local.cnpg_storage_class
                }
              }
            }
          }
        },
        {
          name = "require-wal-ceph-rbd-when-set"
          match = {
            any = [{
              resources = {
                kinds = ["postgresql.cnpg.io/v1/Cluster"]
              }
            }]
          }
          validate = {
            message = "CloudNativePG WAL storage must use ceph-rbd when walStorage is configured."
            pattern = {
              spec = {
                "=(walStorage)" = {
                  storageClass = local.cnpg_storage_class
                }
              }
            }
          }
        },
      ]
    }
  })
}
