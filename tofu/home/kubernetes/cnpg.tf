# =============================================================================
# CloudNativePG
# =============================================================================
# Operator foundation for the eventual per-app PostgreSQL migration.
# Existing app Postgres StatefulSets are not cut over here; migrations happen
# one database at a time after backup/restore proof.

locals {
  cnpg_namespace     = "cnpg-system"
  cnpg_chart_version = "0.28.3"
  cnpg_storage_class = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
}

resource "kubernetes_namespace_v1" "cnpg_system" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.cnpg_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "helm_release" "cnpg" {
  depends_on = [
    kubernetes_namespace_v1.cnpg_system,
    kubernetes_storage_class_v1.ceph_rbd,
  ]

  name       = "cnpg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  namespace  = kubernetes_namespace_v1.cnpg_system.metadata[0].name
  version    = local.cnpg_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    crds = { create = true }

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
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
