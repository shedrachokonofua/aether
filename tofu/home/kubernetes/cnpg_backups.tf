locals {
  cnpg_backup_targets = {
    affine = {
      namespace = local.affine_ns
      cluster   = local.affine_cnpg_cluster
      retention = "14d"
      schedule  = "0 5 2 * * *"
    }
    coder = {
      namespace = local.coder_namespace
      cluster   = local.coder_cnpg_cluster
      retention = "14d"
      schedule  = "0 10 2 * * *"
    }
    firecrawl = {
      namespace = local.firecrawl_ns
      cluster   = local.firecrawl_cnpg_cluster
      retention = "14d"
      schedule  = "0 15 2 * * *"
    }
    hoppscotch = {
      namespace = local.hoppscotch_ns
      cluster   = local.hoppscotch_cnpg_cluster
      retention = "14d"
      schedule  = "0 20 2 * * *"
    }
    kestra = {
      namespace = local.kestra_ns
      cluster   = local.kestra_cnpg_cluster
      retention = "14d"
      schedule  = "0 22 2 * * *"
    }
    immich = {
      namespace = local.immich_namespace
      cluster   = local.immich_cnpg_cluster
      retention = "14d"
      schedule  = "0 25 2 * * *"
    }
    litellm = {
      namespace = local.litellm_ns
      cluster   = local.litellm_cnpg_cluster
      retention = "14d"
      schedule  = "0 30 2 * * *"
    }
    matrix = {
      namespace = local.matrix_ns
      cluster   = local.matrix_cnpg_cluster
      retention = "14d"
      schedule  = "0 35 2 * * *"
    }
    miniflux = {
      namespace = local.miniflux_ns
      cluster   = local.miniflux_cnpg_cluster
      retention = "14d"
      schedule  = "0 40 2 * * *"
    }
    mnemo = {
      namespace = local.mnemo_namespace
      cluster   = local.mnemo_cnpg
      retention = "14d"
      schedule  = "0 0 2 * * *"
    }
    nextcloud = {
      namespace = local.nextcloud_namespace
      cluster   = local.nextcloud_cnpg_cluster
      retention = "14d"
      schedule  = "0 45 2 * * *"
    }
    openwebui = {
      namespace = local.openwebui_namespace
      cluster   = local.openwebui_cnpg_cluster
      retention = "14d"
      schedule  = "0 50 2 * * *"
    }
    temporal = {
      namespace = local.temporal_namespace
      cluster   = local.temporal_cnpg_cluster
      retention = "14d"
      schedule  = "0 55 2 * * *"
    }
  }

  cnpg_scheduled_backup_targets = {
    for name, target in local.cnpg_backup_targets : name => target
    if name != "mnemo"
  }

  cnpg_barman_object_store_targets = local.cnpg_backup_targets

  cnpg_barman_plugin_name = "barman-cloud.cloudnative-pg.io"

  cnpg_barman_object_store_names = {
    for name, target in local.cnpg_backup_targets : name => "${target.cluster}-object-store"
  }

  cnpg_plugin_specs = {
    for name, target in local.cnpg_backup_targets : name => [{
      name          = local.cnpg_barman_plugin_name
      isWALArchiver = true
      parameters = {
        barmanObjectName = local.cnpg_barman_object_store_names[name]
      }
    }]
  }

  cnpg_backup_specs = {
    for name, target in local.cnpg_backup_targets : name => {
      target          = "primary"
      retentionPolicy = target.retention
      barmanObjectStore = {
        destinationPath = "s3://${local.db_backup_bucket}/cnpg/${target.namespace}/${target.cluster}"
        endpointURL     = local.db_backup_s3_endpoint
        s3Credentials = {
          accessKeyId = {
            name = kubernetes_secret_v1.db_backup_s3[target.namespace].metadata[0].name
            key  = "AWS_ACCESS_KEY_ID"
          }
          secretAccessKey = {
            name = kubernetes_secret_v1.db_backup_s3[target.namespace].metadata[0].name
            key  = "AWS_SECRET_ACCESS_KEY"
          }
          region = {
            name = kubernetes_secret_v1.db_backup_s3[target.namespace].metadata[0].name
            key  = "AWS_DEFAULT_REGION"
          }
        }
        wal = {
          compression = "gzip"
        }
        data = {
          compression = "gzip"
        }
      }
    }
  }
}

resource "kubectl_manifest" "mnemo_recovery_object_store" {
  depends_on = [
    helm_release.cnpg_barman_cloud,
    kubernetes_secret_v1.db_backup_s3["mnemo"],
  ]

  yaml_body = yamlencode({
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata = {
      name      = local.mnemo_recovery_object_store_name
      namespace = local.mnemo_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "tofu"
        "aether.sh/backup-kind"        = "cnpg-recovery"
      }
    }
    spec = {
      configuration = merge(local.cnpg_backup_specs["mnemo"].barmanObjectStore, {
        destinationPath = "s3://${local.db_backup_bucket}/cnpg/infra/${local.mnemo_cnpg}"
      })
      retentionPolicy = local.cnpg_backup_targets["mnemo"].retention
    }
  })
}

resource "kubectl_manifest" "cnpg_barman_object_store" {
  for_each = local.cnpg_barman_object_store_targets

  depends_on = [
    helm_release.cnpg_barman_cloud,
    kubernetes_secret_v1.db_backup_s3,
  ]

  yaml_body = yamlencode({
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata = {
      name      = local.cnpg_barman_object_store_names[each.key]
      namespace = each.value.namespace
      labels = {
        "app.kubernetes.io/managed-by" = "tofu"
        "aether.sh/backup-kind"        = "cnpg"
      }
    }
    spec = {
      configuration   = local.cnpg_backup_specs[each.key].barmanObjectStore
      retentionPolicy = each.value.retention
    }
  })
}

resource "kubectl_manifest" "cnpg_scheduled_backup" {
  for_each = local.cnpg_scheduled_backup_targets

  depends_on = [
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_barman_object_store,
    kubectl_manifest.affine_cnpg_cluster,
    kubectl_manifest.coder_cnpg_cluster,
    kubectl_manifest.firecrawl_cnpg_cluster,
    kubectl_manifest.hoppscotch_cnpg_cluster,
    kubectl_manifest.kestra_cnpg_cluster,
    kubectl_manifest.immich_cnpg_cluster,
    kubectl_manifest.litellm_cnpg_cluster,
    kubectl_manifest.matrix_cnpg_cluster,
    kubectl_manifest.miniflux_cnpg_cluster,
    kubectl_manifest.nextcloud_cnpg_cluster,
    kubectl_manifest.openwebui_cnpg_cluster,
    kubectl_manifest.temporal_cnpg_cluster,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "${each.value.cluster}-backup"
      namespace = each.value.namespace
      labels = {
        "app.kubernetes.io/managed-by" = "tofu"
        "aether.sh/backup-kind"        = "cnpg"
      }
    }
    spec = {
      schedule             = each.value.schedule
      backupOwnerReference = "self"
      method               = "plugin"
      target               = "primary"
      pluginConfiguration = {
        name = local.cnpg_barman_plugin_name
      }
      cluster = {
        name = each.value.cluster
      }
    }
  })
}
