# =============================================================================
# Interim Database Backups
# =============================================================================
# Logical dumps land in SeaweedFS first. Backup-stack syncs the SeaweedFS dump
# bucket into /mnt/hdd/data so Backrest can carry it offsite without giving
# Kubernetes AWS credentials.

locals {
  db_backup_bucket      = "aether-db-dumps"
  db_backup_s3_endpoint = "https://s3.seaweed.home.shdr.ch"
  db_backup_pg_image    = "postgres:18-alpine"
  db_backup_aws_image   = "amazon/aws-cli:2.22.35"

  db_backup_postgres_targets = {
    affine = {
      namespace = "affine"
      name      = "affine-postgres"
      service   = "${local.affine_cnpg_cluster}-rw"
      user      = "affine"
      database  = "affine"
      port      = 5432
      schedule  = "03 1 * * *"
    }
    coder = {
      namespace = "coder"
      name      = "coder-postgres"
      service   = "${local.coder_cnpg_cluster}-rw"
      user      = local.coder_postgres_user
      database  = local.coder_postgres_db
      port      = local.coder_postgres_port
      schedule  = "08 1 * * *"
    }
    dawarich = {
      namespace = "dawarich"
      name      = "dawarich-postgres"
      service   = "dawarich-postgres"
      user      = "postgres"
      database  = "dawarich_production"
      port      = 5432
      schedule  = "13 1 * * *"
    }
    firecrawl = {
      namespace = "infra"
      name      = "firecrawl-postgres"
      service   = "${local.firecrawl_cnpg_cluster}-rw"
      user      = local.firecrawl_db_user
      database  = "postgres"
      port      = 5432
      schedule  = "18 1 * * *"
    }
    hoppscotch = {
      namespace = "hoppscotch"
      name      = "hoppscotch-postgres"
      service   = "${local.hoppscotch_cnpg_cluster}-rw"
      user      = "hoppscotch"
      database  = "hoppscotch"
      port      = local.hoppscotch_pg_port
      schedule  = "23 1 * * *"
    }
    immich = {
      namespace = "immich"
      name      = "immich-postgres"
      service   = "${local.immich_cnpg_cluster}-rw"
      user      = local.immich_db_user
      database  = local.immich_db_name
      port      = local.immich_postgres_port
      schedule  = "28 1 * * *"
    }
    litellm = {
      namespace = "infra"
      name      = "litellm-postgres"
      service   = "litellm-postgres-backup"
      user      = "litellm"
      database  = "litellm"
      port      = local.litellm_postgres_port
      schedule  = "33 1 * * *"
    }
    matrix = {
      namespace = "matrix"
      name      = "matrix-postgres"
      service   = "${local.matrix_cnpg_cluster}-rw"
      user      = local.matrix_pg_user
      database  = local.matrix_pg_user
      port      = local.matrix_pg_port
      schedule  = "38 1 * * *"
    }
    miniflux = {
      namespace = "miniflux"
      name      = "miniflux-postgres"
      service   = "${local.miniflux_cnpg_cluster}-rw"
      user      = "miniflux"
      database  = "miniflux"
      port      = local.miniflux_pg_port
      schedule  = "43 1 * * *"
    }
    nextcloud = {
      namespace = "nextcloud"
      name      = "nextcloud-postgres"
      service   = "${local.nextcloud_cnpg_cluster}-rw"
      user      = local.nextcloud_db_user
      database  = local.nextcloud_db_name
      port      = local.nextcloud_postgres_port
      schedule  = "48 1 * * *"
    }
    openwebui = {
      namespace = "infra"
      name      = "openwebui-postgres"
      service   = "${local.openwebui_cnpg_cluster}-rw"
      user      = local.postgres_user
      database  = local.postgres_db
      port      = local.postgres_port
      schedule  = "53 1 * * *"
    }
    temporal = {
      namespace = "temporal"
      name      = "temporal-postgres"
      service   = "${local.temporal_cnpg_cluster}-rw"
      user      = local.temporal_pg_user
      database  = local.temporal_pg_db
      port      = local.temporal_pg_port
      schedule  = "58 1 * * *"
    }
  }

  db_backup_postgres_users = {
    litellm = var.secrets["litellm.database_user"]
  }

  db_backup_postgres_passwords = {
    affine     = random_password.affine_db_password.result
    coder      = random_password.coder_postgres_password.result
    dawarich   = random_password.dawarich_postgres_password.result
    firecrawl  = var.secrets["firecrawl.database_password"]
    hoppscotch = random_password.hoppscotch_postgres_password.result
    immich     = random_password.immich_postgres_password.result
    litellm    = var.secrets["litellm.database_password"]
    matrix     = var.secrets["matrix.database_password"]
    miniflux   = random_password.miniflux_postgres_password.result
    nextcloud  = var.secrets["nextcloud.dbpassword"]
    openwebui  = random_password.openwebui_postgres_password.result
    temporal   = random_password.temporal_postgres_password.result
  }

  db_backup_sidecar_postgres_services = {
    firecrawl = {
      namespace         = "infra"
      service           = "firecrawl-postgres-backup"
      labels            = { app = "firecrawl-postgres-backup" }
      selector          = local.firecrawl_labels
      publish_not_ready = true
    }
    litellm = {
      namespace         = "infra"
      service           = "litellm-postgres-backup"
      labels            = { app = "litellm-postgres-backup" }
      selector          = local.litellm_labels
      publish_not_ready = true
    }
  }

  db_backup_mongo_targets = {
    yourspotify = {
      namespace = "yourspotify"
      name      = "yourspotify-mongo"
      service   = "yourspotify-mongo"
      database  = "your_spotify"
      port      = 27017
      schedule  = "07 2 * * *"
    }
  }

  db_backup_namespaces = toset(distinct(concat(
    [for target in values(local.db_backup_postgres_targets) : target.namespace],
    [for target in values(local.db_backup_mongo_targets) : target.namespace]
  )))
}

resource "kubernetes_secret_v1" "db_backup_s3" {
  for_each = local.db_backup_namespaces

  metadata {
    name      = "db-backup-s3"
    namespace = each.key
    labels = {
      "aether.shdr.ch/component" = "db-backup"
    }
  }

  data = {
    AWS_ACCESS_KEY_ID                = var.secrets["seaweedfs.s3_admin_access_key"]
    AWS_SECRET_ACCESS_KEY            = var.secrets["seaweedfs.s3_admin_secret_key"]
    AWS_DEFAULT_REGION               = "us-east-1"
    AWS_EC2_METADATA_DISABLED        = "true"
    AWS_REQUEST_CHECKSUM_CALCULATION = "WHEN_REQUIRED"
    AWS_RESPONSE_CHECKSUM_VALIDATION = "WHEN_REQUIRED"
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "db_backup_postgres_credentials" {
  for_each = local.db_backup_postgres_targets

  metadata {
    name      = "db-backup-${each.key}-postgres"
    namespace = each.value.namespace
    labels = {
      "aether.shdr.ch/component" = "db-backup"
    }
  }

  data = {
    PGUSER     = lookup(local.db_backup_postgres_users, each.key, each.value.user)
    PGDATABASE = each.value.database
    PGPASSWORD = local.db_backup_postgres_passwords[each.key]
  }

  type = "Opaque"
}

resource "kubernetes_service_v1" "db_backup_sidecar_postgres" {
  for_each = local.db_backup_sidecar_postgres_services

  metadata {
    name      = each.value.service
    namespace = each.value.namespace
    labels    = each.value.labels
  }

  spec {
    selector                    = each.value.selector
    publish_not_ready_addresses = lookup(each.value, "publish_not_ready", false)

    port {
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_manifest" "db_backup_postgres_cronjob" {
  for_each = local.db_backup_postgres_targets

  depends_on = [
    kubernetes_secret_v1.db_backup_s3,
    kubernetes_secret_v1.db_backup_postgres_credentials,
    kubernetes_service_v1.db_backup_sidecar_postgres,
  ]

  manifest = {
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata = {
      name      = "db-backup-${each.key}"
      namespace = each.value.namespace
      labels = {
        "aether.shdr.ch/component" = "db-backup"
        "aether.shdr.ch/database"  = each.value.name
      }
    }
    spec = {
      schedule                   = each.value.schedule
      concurrencyPolicy          = "Forbid"
      successfulJobsHistoryLimit = 3
      failedJobsHistoryLimit     = 2
      jobTemplate = {
        spec = {
          backoffLimit            = 1
          ttlSecondsAfterFinished = 259200
          template = {
            metadata = {
              labels = {
                "aether.shdr.ch/component" = "db-backup"
                "aether.shdr.ch/database"  = each.value.name
              }
            }
            spec = {
              restartPolicy      = "Never"
              enableServiceLinks = false
              securityContext = {
                runAsNonRoot = true
                runAsUser    = 65532
                runAsGroup   = 65532
                fsGroup      = 65532

                fsGroupChangePolicy = "OnRootMismatch"

                seccompProfile = {
                  type = "RuntimeDefault"
                }
              }
              volumes = [
                {
                  name     = "backup"
                  emptyDir = {}
                }
              ]
              initContainers = [
                {
                  name    = "dump"
                  image   = local.db_backup_pg_image
                  command = ["/bin/sh", "-ec"]
                  args = [<<-EOT
                    ts="$(date -u +%Y%m%dT%H%M%SZ)"
                    out="/backup/$BACKUP_NAME-$ts.dump"
                    pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE"
                    pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" --format=custom --no-owner --file "$out"
                    sha256sum "$out" > "$out.sha256"
                  EOT
                  ]
                  envFrom = [
                    {
                      secretRef = {
                        name = kubernetes_secret_v1.db_backup_postgres_credentials[each.key].metadata[0].name
                      }
                    }
                  ]
                  env = [
                    {
                      name  = "BACKUP_NAME"
                      value = each.value.name
                    },
                    {
                      name  = "PGHOST"
                      value = "${each.value.service}.${each.value.namespace}.svc.cluster.local"
                    },
                    {
                      name  = "PGPORT"
                      value = tostring(each.value.port)
                    }
                  ]
                  volumeMounts = [
                    {
                      name      = "backup"
                      mountPath = "/backup"
                    }
                  ]
                  securityContext = {
                    allowPrivilegeEscalation = false
                    capabilities = {
                      drop = ["ALL"]
                    }
                  }
                }
              ]
              containers = [
                {
                  name    = "upload"
                  image   = local.db_backup_aws_image
                  command = ["/bin/sh", "-ec"]
                  args = [<<-EOT
                    export HOME=/tmp/aws
                    mkdir -p "$HOME/.aws"
                    printf '%s\n' '[default]' 's3 =' '  addressing_style = path' > "$HOME/.aws/config"
                    aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 || \
                      aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
                    for f in /backup/*; do
                      [ -f "$f" ] || continue
                      aws --endpoint-url "$S3_ENDPOINT" s3api put-object \
                        --bucket "$S3_BUCKET" \
                        --key "$S3_PREFIX/$(basename "$f")" \
                        --body "$f" >/dev/null
                    done
                  EOT
                  ]
                  envFrom = [
                    {
                      secretRef = {
                        name = kubernetes_secret_v1.db_backup_s3[each.value.namespace].metadata[0].name
                      }
                    }
                  ]
                  env = [
                    {
                      name  = "S3_ENDPOINT"
                      value = local.db_backup_s3_endpoint
                    },
                    {
                      name  = "S3_BUCKET"
                      value = local.db_backup_bucket
                    },
                    {
                      name  = "S3_PREFIX"
                      value = "postgres/${each.value.namespace}/${each.value.name}"
                    }
                  ]
                  volumeMounts = [
                    {
                      name      = "backup"
                      mountPath = "/backup"
                    }
                  ]
                  securityContext = {
                    allowPrivilegeEscalation = false
                    capabilities = {
                      drop = ["ALL"]
                    }
                  }
                }
              ]
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_manifest" "db_backup_mongo_cronjob" {
  for_each = local.db_backup_mongo_targets

  depends_on = [
    kubernetes_secret_v1.db_backup_s3,
  ]

  manifest = {
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata = {
      name      = "db-backup-${each.key}"
      namespace = each.value.namespace
      labels = {
        "aether.shdr.ch/component" = "db-backup"
        "aether.shdr.ch/database"  = each.value.name
      }
    }
    spec = {
      schedule                   = each.value.schedule
      concurrencyPolicy          = "Forbid"
      successfulJobsHistoryLimit = 3
      failedJobsHistoryLimit     = 2
      jobTemplate = {
        spec = {
          backoffLimit            = 1
          ttlSecondsAfterFinished = 259200
          template = {
            metadata = {
              labels = {
                "aether.shdr.ch/component" = "db-backup"
                "aether.shdr.ch/database"  = each.value.name
              }
            }
            spec = {
              restartPolicy      = "Never"
              enableServiceLinks = false
              securityContext = {
                runAsNonRoot = true
                runAsUser    = 65532
                runAsGroup   = 65532
                fsGroup      = 65532

                fsGroupChangePolicy = "OnRootMismatch"

                seccompProfile = {
                  type = "RuntimeDefault"
                }
              }
              volumes = [
                {
                  name     = "backup"
                  emptyDir = {}
                }
              ]
              initContainers = [
                {
                  name    = "dump"
                  image   = local.yourspotify_mongo_image
                  command = ["/bin/sh", "-ec"]
                  args = [<<-EOT
                    ts="$(date -u +%Y%m%dT%H%M%SZ)"
                    out="/backup/$BACKUP_NAME-$ts.archive.gz"
                    mongodump --host "$MONGO_HOST" --port "$MONGO_PORT" --db "$MONGO_DB" --archive="$out" --gzip
                    sha256sum "$out" > "$out.sha256"
                  EOT
                  ]
                  env = [
                    {
                      name  = "BACKUP_NAME"
                      value = each.value.name
                    },
                    {
                      name  = "MONGO_HOST"
                      value = "${each.value.service}.${each.value.namespace}.svc.cluster.local"
                    },
                    {
                      name  = "MONGO_PORT"
                      value = tostring(each.value.port)
                    },
                    {
                      name  = "MONGO_DB"
                      value = each.value.database
                    }
                  ]
                  volumeMounts = [
                    {
                      name      = "backup"
                      mountPath = "/backup"
                    }
                  ]
                  securityContext = {
                    allowPrivilegeEscalation = false
                    capabilities = {
                      drop = ["ALL"]
                    }
                  }
                }
              ]
              containers = [
                {
                  name    = "upload"
                  image   = local.db_backup_aws_image
                  command = ["/bin/sh", "-ec"]
                  args = [<<-EOT
                    export HOME=/tmp/aws
                    mkdir -p "$HOME/.aws"
                    printf '%s\n' '[default]' 's3 =' '  addressing_style = path' > "$HOME/.aws/config"
                    aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 || \
                      aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
                    for f in /backup/*; do
                      [ -f "$f" ] || continue
                      aws --endpoint-url "$S3_ENDPOINT" s3api put-object \
                        --bucket "$S3_BUCKET" \
                        --key "$S3_PREFIX/$(basename "$f")" \
                        --body "$f" >/dev/null
                    done
                  EOT
                  ]
                  envFrom = [
                    {
                      secretRef = {
                        name = kubernetes_secret_v1.db_backup_s3[each.value.namespace].metadata[0].name
                      }
                    }
                  ]
                  env = [
                    {
                      name  = "S3_ENDPOINT"
                      value = local.db_backup_s3_endpoint
                    },
                    {
                      name  = "S3_BUCKET"
                      value = local.db_backup_bucket
                    },
                    {
                      name  = "S3_PREFIX"
                      value = "mongo/${each.value.namespace}/${each.value.name}"
                    }
                  ]
                  volumeMounts = [
                    {
                      name      = "backup"
                      mountPath = "/backup"
                    }
                  ]
                  securityContext = {
                    allowPrivilegeEscalation = false
                    capabilities = {
                      drop = ["ALL"]
                    }
                  }
                }
              ]
            }
          }
        }
      }
    }
  }
}
