# Personal music discovery and tagging system.
# M0 deliberately deploys only PostgreSQL plus the versioned metadata pipeline;
# runtime services stay disabled until their product contracts are complete.

locals {
  mingus_namespace     = module.namespace["mingus"].name
  mingus_chart_version = "0.1.0-14d6fb9f"
  mingus_image_tag     = "14d6fb9f"
  mingus_labels = {
    app                         = "mingus"
    "app.kubernetes.io/name"    = "mingus"
    "app.kubernetes.io/part-of" = "mingus"
  }
}

resource "kubernetes_secret_v1" "mingus_gitlab_registry" {
  depends_on = [module.namespace["mingus"]]

  metadata {
    name      = "mingus-gitlab-registry"
    namespace = local.mingus_namespace
    labels    = local.mingus_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.gitlab_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

resource "helm_release" "mingus" {
  depends_on = [
    module.namespace["mingus"],
    kubernetes_secret_v1.db_backup_s3["mingus"],
    kubernetes_secret_v1.mingus_gitlab_registry,
    kubernetes_storage_class_v1.ceph_rbd,
  ]

  name       = "mingus"
  repository = "oci://${local.gitlab_registry_host}/so/mingus"
  chart      = "mingus"
  version    = local.mingus_chart_version
  namespace  = local.mingus_namespace
  wait       = true
  atomic     = true
  timeout    = 3600

  values = [yamlencode({
    images = {
      pullSecret = kubernetes_secret_v1.mingus_gitlab_registry.metadata[0].name
      training = {
        repository = "${local.gitlab_registry_host}/so/mingus/training"
        tag        = local.mingus_image_tag
        pullPolicy = "IfNotPresent"
      }
    }

    api            = { enabled = false }
    workers        = { enabled = false }
    infer          = { enabled = false }
    web            = { enabled = false }
    schedules      = { enabled = false }
    externalSecret = { enabled = false }
    audio          = { enabled = false }

    cnpg = {
      enabled      = true
      storageClass = "ceph-rbd"
      backup = {
        enabled         = true
        # -v2: cluster was recreated 2026-08-01; old incarnation's WALs occupy
        # the previous path and CNPG refuses to archive into a non-empty dir.
        destinationPath = "s3://${local.db_backup_bucket}/cnpg/mingus/mingus-v2"
        endpointURL     = local.db_backup_s3_endpoint
        schedule        = "0 0 3 * * *"
        retentionPolicy = "30d"
        secretName      = kubernetes_secret_v1.db_backup_s3["mingus"].metadata[0].name
      }
    }

    m0 = {
      enabled = true
      nodeSelector = {
        "kubernetes.io/hostname" = "talos-smith"
      }
      data = {
        server = "10.0.2.4"
        path   = "/mnt/hdd/data"
      }
      parquetPath        = "/data/ml/eno/raw/metadata/albums.parquet"
      taxonomyPath       = "/data/ml/eno/processed/taxonomy/v1/labels.json"
      corpusManifestPath = "/data/ml/eno/processed/corpus/corpus_manifest.parquet"
      sampleSize         = 40000
    }
  })]
}
