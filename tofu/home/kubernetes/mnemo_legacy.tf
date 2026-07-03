# =============================================================================
# mnemo legacy resources retained during namespace migration
# =============================================================================
# These preserve the existing infra/mnemo-cnpg source cluster and its backup
# schedule while the active mnemo app and restored CNPG cluster move to the
# dedicated mnemo namespace. Remove only after the new namespace has soaked and
# its backups are verified.

resource "kubernetes_secret_v1" "mnemo_cnpg_app_legacy" {
  depends_on = [module.namespace["infra"]]

  metadata {
    name      = "mnemo-cnpg-app"
    namespace = module.namespace["infra"].name
    labels    = local.mnemo_labels
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.mnemo_db_user
    password = var.secrets["mnemo.database_password"]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubectl_manifest" "mnemo_cnpg_cluster_legacy" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.mnemo_cnpg_app_legacy,
    kubernetes_secret_v1.db_backup_s3["infra"],
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.mnemo_cnpg
      namespace = module.namespace["infra"].name
      labels    = merge(local.mnemo_labels, { "aether.sh/arm-ok" = "true" })
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:16.13"
      resources = {
        claims   = []
        requests = { cpu = "250m", memory = "256Mi" }
        limits   = { cpu = "2000m", memory = "2Gi" }
      }
      affinity = { nodeSelector = { "kubernetes.io/arch" = "amd64" } }
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["mnemo_legacy"]
      bootstrap = {
        initdb = {
          database = local.mnemo_db
          owner    = local.mnemo_db_user
          secret = {
            name = kubernetes_secret_v1.mnemo_cnpg_app_legacy.metadata[0].name
          }
          postInitApplicationSQL = [
            "CREATE EXTENSION IF NOT EXISTS vector",
            "CREATE EXTENSION IF NOT EXISTS pg_trgm",
            "CREATE EXTENSION IF NOT EXISTS unaccent"
          ]
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = all
  }
}

resource "kubectl_manifest" "mnemo_cnpg_backup_legacy" {
  depends_on = [kubectl_manifest.mnemo_cnpg_cluster_legacy, kubectl_manifest.cnpg_barman_object_store]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "mnemo-cnpg-backup"
      namespace = module.namespace["infra"].name
    }
    spec = {
      schedule             = "0 0 2 * * *"
      backupOwnerReference = "self"
      method               = "plugin"
      target               = "primary"
      pluginConfiguration = {
        name = local.cnpg_barman_plugin_name
      }
      cluster = {
        name = local.mnemo_cnpg
      }
    }
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = all
  }
}

resource "kubectl_manifest" "mnemo_precutover_backup" {
  depends_on = [
    kubectl_manifest.mnemo_cnpg_cluster_legacy,
    kubectl_manifest.cnpg_barman_object_store["mnemo_legacy"],
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Backup"
    metadata = {
      name      = "mnemo-precutover-backup"
      namespace = module.namespace["infra"].name
      labels = {
        "app.kubernetes.io/managed-by" = "tofu"
        "aether.sh/backup-kind"        = "cnpg-cutover"
      }
    }
    spec = {
      method = "plugin"
      target = "primary"
      pluginConfiguration = {
        name = local.cnpg_barman_plugin_name
      }
      cluster = {
        name = local.mnemo_cnpg
      }
    }
  })
}
