# =============================================================================
# Adopted CloudNativePG clusters
# =============================================================================
# These clusters were cut over live before their declarations landed in Tofu.
# Keep the manifests close to the original kubectl-applied specs so import does
# not recreate data-bearing clusters. The legacy Postgres services remain as
# rollback/import sources until each app's post-cutover cleanup is complete.

resource "kubernetes_secret_v1" "affine_cnpg_app" {
  depends_on = [kubernetes_namespace_v1.affine]

  metadata {
    name      = "affine-cnpg-app"
    namespace = local.affine_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = "affine"
    password = random_password.affine_db_password.result
  }
}

resource "kubectl_manifest" "affine_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.affine_cnpg_app,
    kubernetes_service_v1.affine_postgres,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.affine_cnpg_cluster
      namespace = local.affine_ns
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:16.13"
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      backup = local.cnpg_backup_specs["affine"]
      bootstrap = {
        initdb = {
          database = "affine"
          owner    = "affine"
          secret   = { name = kubernetes_secret_v1.affine_cnpg_app.metadata[0].name }
          postInitApplicationSQL = [
            "CREATE EXTENSION IF NOT EXISTS pgcrypto",
            "CREATE EXTENSION IF NOT EXISTS vector",
          ]
          import = {
            type      = "microservice"
            databases = ["affine"]
            source    = { externalCluster = "affine-source" }
          }
        }
      }
      externalClusters = [{
        name = "affine-source"
        connectionParameters = {
          host    = "affine-postgres.${local.affine_ns}.svc.cluster.local"
          user    = "affine"
          dbname  = "affine"
          sslmode = "disable"
        }
        password = {
          name = kubernetes_secret_v1.affine_postgres.metadata[0].name
          key  = "POSTGRES_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "immich_cnpg_app" {
  depends_on = [kubernetes_namespace_v1.immich]

  metadata {
    name      = "immich-cnpg-app"
    namespace = local.immich_namespace
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.immich_db_user
    password = random_password.immich_postgres_password.result
  }
}

resource "kubectl_manifest" "immich_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.immich_cnpg_app,
    kubernetes_service_v1.immich_postgres,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.immich_cnpg_cluster
      namespace = local.immich_namespace
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/tensorchord/cloudnative-vectorchord:14-0.4.3"
      storage = {
        size         = "30Gi"
        storageClass = local.cnpg_storage_class
      }
      postgresql = {
        shared_preload_libraries = ["vchord.so"]
        parameters = {
          max_wal_size    = "2GB"
          shared_buffers  = "512MB"
          wal_compression = "on"
        }
      }
      backup = local.cnpg_backup_specs["immich"]
      bootstrap = {
        initdb = {
          database = local.immich_db_name
          owner    = local.immich_db_user
          secret   = { name = kubernetes_secret_v1.immich_cnpg_app.metadata[0].name }
          import = {
            type      = "microservice"
            databases = [local.immich_db_name]
            source    = { externalCluster = "immich-source" }
          }
        }
      }
      externalClusters = [{
        name = "immich-source"
        connectionParameters = {
          host    = "immich-postgres.${local.immich_namespace}.svc.cluster.local"
          user    = local.immich_db_user
          dbname  = local.immich_db_name
          sslmode = "disable"
        }
        password = {
          name = kubernetes_secret_v1.immich_postgres.metadata[0].name
          key  = "POSTGRES_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "litellm_cnpg_app" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "litellm-cnpg-app"
    namespace = local.litellm_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = var.secrets["litellm.database_user"]
    password = var.secrets["litellm.database_password"]
  }
}

resource "kubectl_manifest" "litellm_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.litellm_cnpg_app,
    kubernetes_service_v1.db_backup_sidecar_postgres["litellm"],
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.litellm_cnpg_cluster
      namespace = local.litellm_ns
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:18.4"
      storage = {
        size         = "20Gi"
        storageClass = local.cnpg_storage_class
      }
      backup = local.cnpg_backup_specs["litellm"]
      bootstrap = {
        initdb = {
          database      = "litellm"
          owner         = var.secrets["litellm.database_user"]
          localeCType   = "en_US.utf8"
          localeCollate = "en_US.utf8"
          secret        = { name = kubernetes_secret_v1.litellm_cnpg_app.metadata[0].name }
          import = {
            type      = "microservice"
            databases = ["litellm"]
            source    = { externalCluster = "litellm-source" }
          }
        }
      }
      externalClusters = [{
        name = "litellm-source"
        connectionParameters = {
          host    = "litellm-postgres-backup.${local.litellm_ns}.svc.cluster.local"
          user    = var.secrets["litellm.database_user"]
          dbname  = "litellm"
          sslmode = "disable"
        }
        password = {
          name = "litellm-env"
          key  = "POSTGRES_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "openwebui_cnpg_app" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "openwebui-cnpg-app"
    namespace = local.openwebui_namespace
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.postgres_user
    password = random_password.openwebui_postgres_password.result
  }
}

resource "kubectl_manifest" "openwebui_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.openwebui_cnpg_app,
    kubernetes_service_v1.openwebui_postgres,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.openwebui_cnpg_cluster
      namespace = local.openwebui_namespace
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:16.13"
      storage = {
        size         = "20Gi"
        storageClass = local.cnpg_storage_class
      }
      backup = local.cnpg_backup_specs["openwebui"]
      bootstrap = {
        initdb = {
          database = local.postgres_db
          owner    = local.postgres_user
          secret   = { name = kubernetes_secret_v1.openwebui_cnpg_app.metadata[0].name }
          postInitApplicationSQL = [
            "CREATE EXTENSION IF NOT EXISTS vector",
          ]
          import = {
            type      = "microservice"
            databases = [local.postgres_db]
            source    = { externalCluster = "openwebui-source" }
          }
        }
      }
      externalClusters = [{
        name = "openwebui-source"
        connectionParameters = {
          host    = "openwebui-postgres.${local.openwebui_namespace}.svc.cluster.local"
          user    = local.postgres_user
          dbname  = local.postgres_db
          sslmode = "disable"
        }
        password = {
          name = kubernetes_secret_v1.openwebui_postgres.metadata[0].name
          key  = "POSTGRES_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "matrix_cnpg_app" {
  depends_on = [kubernetes_namespace_v1.matrix]

  metadata {
    name      = "matrix-cnpg-app"
    namespace = local.matrix_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.matrix_pg_user
    password = var.secrets["matrix.database_password"]
  }
}

resource "kubectl_manifest" "matrix_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.matrix_cnpg_app,
    kubernetes_service_v1.matrix_postgres,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.matrix_cnpg_cluster
      namespace = local.matrix_ns
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:17.9"
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      backup = local.cnpg_backup_specs["matrix"]
      bootstrap = {
        initdb = {
          database      = "app"
          owner         = local.matrix_pg_user
          localeCType   = "C"
          localeCollate = "C"
          secret        = { name = kubernetes_secret_v1.matrix_cnpg_app.metadata[0].name }
          import = {
            type      = "monolith"
            databases = ["matrix", "mautrix_whatsapp", "mautrix_gmessages"]
            source    = { externalCluster = "matrix-source" }
          }
        }
      }
      externalClusters = [{
        name = "matrix-source"
        connectionParameters = {
          host    = "matrix-postgres.${local.matrix_ns}.svc.cluster.local"
          user    = local.matrix_pg_user
          dbname  = local.matrix_pg_user
          sslmode = "disable"
        }
        password = {
          name = kubernetes_secret_v1.matrix_postgres.metadata[0].name
          key  = "POSTGRES_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "nextcloud_cnpg_app" {
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "nextcloud-cnpg-app"
    namespace = local.nextcloud_namespace
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.nextcloud_cnpg_user
    password = var.secrets["nextcloud.dbpassword"]
  }
}

resource "kubectl_manifest" "nextcloud_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.nextcloud_cnpg_app,
    kubernetes_service_v1.nextcloud_postgres,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.nextcloud_cnpg_cluster
      namespace = local.nextcloud_namespace
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:16.13"
      storage = {
        size         = "20Gi"
        storageClass = local.cnpg_storage_class
      }
      backup = local.cnpg_backup_specs["nextcloud"]
      bootstrap = {
        initdb = {
          database = local.nextcloud_db_name
          owner    = local.nextcloud_cnpg_user
          secret   = { name = kubernetes_secret_v1.nextcloud_cnpg_app.metadata[0].name }
          import = {
            type      = "microservice"
            databases = [local.nextcloud_db_name]
            source    = { externalCluster = "nextcloud-source" }
          }
        }
      }
      externalClusters = [{
        name = "nextcloud-source"
        connectionParameters = {
          host    = "nextcloud-postgres.${local.nextcloud_namespace}.svc.cluster.local"
          user    = local.nextcloud_db_user
          dbname  = local.nextcloud_db_name
          sslmode = "disable"
        }
        password = {
          name = kubernetes_secret_v1.nextcloud_postgres.metadata[0].name
          key  = "POSTGRES_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}
