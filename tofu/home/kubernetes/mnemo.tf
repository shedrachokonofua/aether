# =============================================================================
# mnemo — personal memory service
# =============================================================================
# Elixir/Phoenix app ingesting OpenWebUI, Matrix, and email into a unified
# message model with RAG, API, and MCP transport.
# Docs: ../mnemo/docs/HANDOFF.md, ../mnemo/docs/DEPLOYMENT.md

locals {
  mnemo_namespace     = module.namespace["mnemo"].name
  mnemo_host          = "mnemo.home.shdr.ch"
  mnemo_image         = "registry.gitlab.home.shdr.ch/so/mnemo:latest"
  mnemo_port          = 4000
  mnemo_chart_version = "0.1.0-07415e0b"
  mnemo_image_tag     = "07415e0b"
  mnemo_cnpg          = "mnemo-cnpg"
  mnemo_db            = "mnemo"
  mnemo_db_user       = "mnemo"
  mnemo_db_service    = "${local.mnemo_cnpg}-rw.${local.mnemo_namespace}.svc.cluster.local"
  mnemo_db_url        = "postgresql://${local.mnemo_db_user}:${kubernetes_secret_v1.mnemo_cnpg_app.data["password"]}@${local.mnemo_db_service}:5432/${local.mnemo_db}?sslmode=disable"

  mnemo_openwebui_db_host = "${local.openwebui_cnpg_cluster}-rw.${local.openwebui_namespace}.svc.cluster.local"
  mnemo_openwebui_db_url  = "postgresql://${local.postgres_user}:${kubernetes_secret_v1.openwebui_cnpg_app.data["password"]}@${local.mnemo_openwebui_db_host}:${local.postgres_port}/${local.postgres_db}?sslmode=disable"

  mnemo_seaweed_endpoint           = "https://s3.seaweed.home.shdr.ch"
  mnemo_seaweed_bucket             = "mnemo-objects"
  mnemo_recovery_object_store_name = "${local.mnemo_cnpg}-object-store-recovery"

  mnemo_labels         = { app = "mnemo" }
  gitlab_registry_host = "registry.gitlab.home.shdr.ch"
}

# --- Secrets -----------------------------------------------------------------

resource "kubernetes_secret_v1" "mnemo_env" {
  depends_on = [
    module.namespace["mnemo"],
    kubernetes_secret_v1.openwebui_cnpg_app,
  ]

  metadata {
    name      = "mnemo-env"
    namespace = local.mnemo_namespace
    labels    = local.mnemo_labels
  }

  data = {
    DATABASE_URL    = local.mnemo_db_url
    SECRET_KEY_BASE = var.secrets["mnemo.secret_key_base"]
    PHX_HOST        = local.mnemo_host
    PHX_SERVER      = "true"

    # Seaweed S3 object storage
    SEAWEED_S3_ENDPOINT   = local.mnemo_seaweed_endpoint
    SEAWEED_S3_BUCKET     = local.mnemo_seaweed_bucket
    SEAWEED_S3_ACCESS_KEY = var.secrets["seaweedfs.s3_admin_access_key"]
    SEAWEED_S3_SECRET_KEY = var.secrets["seaweedfs.s3_admin_secret_key"]

    # LiteLLM embeddings
    LITELLM_EMBEDDING_BASE_URL = "http://litellm.litellm.svc.cluster.local:4000"
    LITELLM_EMBEDDING_API_KEY  = var.secrets["litellm.master_key"]
    LITELLM_EMBEDDING_MODEL    = "text-embedding-3-large"

    # OpenWebUI source (read-only API access)
    OPENWEBUI_DATABASE_URL = local.mnemo_openwebui_db_url
    OPENWEBUI_API_KEY      = var.secrets["openwebui.mcpo_api_key"]

    # Matrix source (bot user access token)
    MATRIX_HOMESERVER_URL = "https://matrix.home.shdr.ch"
    MATRIX_ACCESS_TOKEN   = var.secrets["matrix.mnemo_bot_access_token"]

    # Gmail source (OAuth refresh token)
    GMAIL_CLIENT_ID     = var.secrets["gmail.client_id"]
    GMAIL_CLIENT_SECRET = var.secrets["gmail.client_secret"]
    GMAIL_REFRESH_TOKEN = var.secrets["gmail.refresh_token"]

    # OTEL (Aether in-cluster collector)
    # opentelemetry_exporter uses HTTP (:httpc); collector HTTP receiver is 4318 (4317 is gRPC).
    OTEL_SERVICE_NAME           = "mnemo"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-daemonset-opentelemetry-collector.system.svc.cluster.local:4318"
    OTEL_RESOURCE_ATTRIBUTES    = "service.namespace=mnemo,deployment.environment=home"

    # Meilisearch keyword search index
    MEILI_MASTER_KEY = var.secrets["meilisearch.master_key"]
    MEILI_INDEX      = "messages"
  }

  type = "Opaque"
}

# CNPG app secret (username/password for the mnemo CNPG cluster)
resource "kubernetes_secret_v1" "mnemo_cnpg_app" {
  depends_on = [module.namespace["mnemo"]]

  metadata {
    name      = "mnemo-cnpg-app"
    namespace = local.mnemo_namespace
    labels    = local.mnemo_labels
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.mnemo_db_user
    password = var.secrets["mnemo.database_password"]
  }
}

# --- CNPG Postgres Cluster ---------------------------------------------------

resource "kubectl_manifest" "mnemo_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.mnemo_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.mnemo_cnpg
      namespace = local.mnemo_namespace
      labels    = merge(local.mnemo_labels, { "aether.sh/arm-ok" = "true" })
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:16.14"
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
      plugins = local.cnpg_plugin_specs["mnemo"]
      bootstrap = {
        initdb = {
          database = local.mnemo_db
          owner    = local.mnemo_db_user
          secret = {
            name = kubernetes_secret_v1.mnemo_cnpg_app.metadata[0].name
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
  }
}

# --- Database Migration + Source Bootstrap -----------------------------------
resource "kubernetes_job_v1" "mnemo_migration" {
  depends_on = [
    kubectl_manifest.mnemo_cnpg_cluster,
    kubernetes_secret_v1.mnemo_env,
  ]


  metadata {
    name      = "mnemo-migrate"
    namespace = local.mnemo_namespace
    labels    = merge(local.mnemo_labels, { job = "mnemo-migrate" })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = merge(local.mnemo_labels, { job = "mnemo-migrate" })
      }

      spec {
        restart_policy       = "OnFailure"
        enable_service_links = false
        node_selector        = { "kubernetes.io/arch" = "amd64" }

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "migrate"
          image             = local.mnemo_image
          image_pull_policy = "Always"
          command           = ["/app/bin/mnemo", "eval", "Mnemo.Release.migrate()"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mnemo_env.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }
      }
    }

    completions = 1
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

resource "kubernetes_job_v1" "mnemo_bootstrap_openwebui" {
  depends_on = [
    kubernetes_job_v1.mnemo_migration,
    kubernetes_secret_v1.mnemo_env,
  ]

  metadata {
    name      = "mnemo-bootstrap-openwebui"
    namespace = local.mnemo_namespace
    labels    = merge(local.mnemo_labels, { job = "mnemo-bootstrap-openwebui" })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = merge(local.mnemo_labels, { job = "mnemo-bootstrap-openwebui" })
      }

      spec {
        restart_policy       = "OnFailure"
        enable_service_links = false
        node_selector        = { "kubernetes.io/arch" = "amd64" }

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "bootstrap"
          image             = local.mnemo_image
          image_pull_policy = "Always"
          command = ["/app/bin/mnemo", "eval", <<-EOT
            Application.ensure_all_started(:mnemo)

            result =
              Mnemo.Repo.query!("""
              WITH existing AS (
                SELECT id
                FROM source_accounts
                WHERE source_kind = 'openwebui' AND name = 'default'
                LIMIT 1
              ),
              inserted AS (
                INSERT INTO source_accounts (source_kind, name, config, enabled, inserted_at, updated_at)
                SELECT 'openwebui', 'default', jsonb_build_object('database_url_configured', true), true, now(), now()
                WHERE NOT EXISTS (SELECT 1 FROM existing)
                RETURNING id
              )
              SELECT id FROM inserted
              UNION ALL
              SELECT id FROM existing
              LIMIT 1
              """)

            [[source_account_id]] = result.rows

            IO.puts("openwebui source_account_id=" <> Ecto.UUID.cast!(source_account_id))

            job =
              Mnemo.Jobs.SyncOpenWebUI.new(Map.new(),
                unique: [
                  period: 3600,
                  fields: [:worker, :queue, :args],
                  states: [:available, :scheduled, :executing, :retryable]
                ]
              )

            case Oban.insert(job) do
              {:ok, job} -> IO.puts("queued openwebui sync job " <> Integer.to_string(job.id))
              {:error, changeset} -> IO.puts("openwebui sync job not queued: " <> inspect(changeset.errors))
            end
          EOT
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mnemo_env.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }
      }
    }

    completions = 1
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}
resource "kubernetes_job_v1" "mnemo_bootstrap_gmail" {
  depends_on = [
    kubernetes_job_v1.mnemo_migration,
    kubernetes_secret_v1.mnemo_env,
  ]

  metadata {
    name      = "mnemo-bootstrap-gmail"
    namespace = local.mnemo_namespace
    labels    = merge(local.mnemo_labels, { job = "mnemo-bootstrap-gmail" })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = merge(local.mnemo_labels, { job = "mnemo-bootstrap-gmail" })
      }

      spec {
        restart_policy       = "OnFailure"
        enable_service_links = false
        node_selector        = { "kubernetes.io/arch" = "amd64" }

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "bootstrap"
          image             = local.mnemo_image
          image_pull_policy = "Always"
          command = ["/app/bin/mnemo", "eval", <<-EOT
            Application.ensure_all_started(:mnemo)

            result =
              Mnemo.Repo.query!("""
              WITH existing AS (
                SELECT id
                FROM source_accounts
                WHERE source_kind = 'email' AND name = 'default'
                LIMIT 1
              ),
              inserted AS (
                INSERT INTO source_accounts (source_kind, name, config, enabled, inserted_at, updated_at)
                SELECT 'email', 'default', '{}'::jsonb, true, now(), now()
                WHERE NOT EXISTS (SELECT 1 FROM existing)
                RETURNING id
              )
              SELECT id FROM inserted
              UNION ALL
              SELECT id FROM existing
              LIMIT 1
              """)

            [[source_account_id]] = result.rows

            IO.puts("email source_account_id=" <> Ecto.UUID.cast!(source_account_id))

            job =
              Mnemo.Jobs.SyncGmail.new(%%{"source_account_id" => Ecto.UUID.cast!(source_account_id)},
                unique: [
                  period: 3600,
                  fields: [:worker, :queue, :args],
                  states: [:available, :scheduled, :executing, :retryable]
                ]
              )

            case Oban.insert(job) do
              {:ok, job} -> IO.puts("queued gmail sync job " <> Integer.to_string(job.id))
              {:error, changeset} -> IO.puts("gmail sync job not queued: " <> inspect(changeset.errors))
            end
          EOT
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mnemo_env.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }
      }
    }

    completions = 1
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}


resource "kubernetes_job_v1" "mnemo_bootstrap_matrix" {
  depends_on = [
    kubernetes_job_v1.mnemo_migration,
    kubernetes_secret_v1.mnemo_env,
  ]

  metadata {
    name      = "mnemo-bootstrap-matrix"
    namespace = local.mnemo_namespace
    labels    = merge(local.mnemo_labels, { job = "mnemo-bootstrap-matrix" })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = merge(local.mnemo_labels, { job = "mnemo-bootstrap-matrix" })
      }

      spec {
        restart_policy       = "OnFailure"
        enable_service_links = false
        node_selector        = { "kubernetes.io/arch" = "amd64" }

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "bootstrap"
          image             = local.mnemo_image
          image_pull_policy = "Always"
          command = ["/app/bin/mnemo", "eval", <<-EOT
            Application.ensure_all_started(:mnemo)

            result =
              Mnemo.Repo.query!("""
              WITH existing AS (
                SELECT id
                FROM source_accounts
                WHERE source_kind = 'matrix' AND name = 'default'
                LIMIT 1
              ),
              inserted AS (
                INSERT INTO source_accounts (source_kind, name, config, enabled, inserted_at, updated_at)
                SELECT 'matrix', 'default', jsonb_build_object('homeserver', 'https://matrix.home.shdr.ch'), true, now(), now()
                WHERE NOT EXISTS (SELECT 1 FROM existing)
                RETURNING id
              )
              SELECT id FROM inserted
              UNION ALL
              SELECT id FROM existing
              LIMIT 1
              """)

            [[source_account_id]] = result.rows

            IO.puts("matrix source_account_id=" <> Ecto.UUID.cast!(source_account_id))

            job =
              Mnemo.Jobs.SyncMatrix.new(%%{"source_account_id" => Ecto.UUID.cast!(source_account_id)},
                unique: [
                  period: 3600,
                  fields: [:worker, :queue, :args],
                  states: [:available, :scheduled, :executing, :retryable]
                ]
              )

            case Oban.insert(job) do
              {:ok, job} -> IO.puts("queued matrix sync job " <> Integer.to_string(job.id))
              {:error, changeset} -> IO.puts("matrix sync job not queued: " <> inspect(changeset.errors))
            end
          EOT
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mnemo_env.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }
        }
      }
    }

    completions = 1
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}



# --- GitLab Registry Pull Secret --------------------------------------------

resource "kubernetes_secret_v1" "mnemo_gitlab_registry" {
  depends_on = [module.namespace["mnemo"]]

  metadata {
    name      = "mnemo-gitlab-registry"
    namespace = local.mnemo_namespace
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

# --- Helm Release ------------------------------------------------------------

resource "helm_release" "mnemo" {
  depends_on = [
    kubectl_manifest.mnemo_cnpg_cluster,
    kubernetes_job_v1.mnemo_migration,
    kubernetes_job_v1.mnemo_bootstrap_openwebui,
    kubernetes_job_v1.mnemo_bootstrap_gmail,
    kubernetes_job_v1.mnemo_bootstrap_matrix,
    kubernetes_secret_v1.mnemo_env,
    kubernetes_secret_v1.mnemo_gitlab_registry,
    kubernetes_storage_class_v1.ceph_rbd,
    kubernetes_manifest.main_gateway,
  ]

  name       = "mnemo"
  repository = "oci://${local.gitlab_registry_host}/so/mnemo"
  chart      = "mnemo"
  version    = local.mnemo_chart_version
  namespace  = local.mnemo_namespace
  wait       = true
  atomic     = true
  timeout    = 900

  values = [yamlencode({
    image = {
      repository = "registry.gitlab.home.shdr.ch/so/mnemo"
      tag        = local.mnemo_image_tag
      pullSecret = kubernetes_secret_v1.mnemo_gitlab_registry.metadata[0].name
    }

    envSecretName = kubernetes_secret_v1.mnemo_env.metadata[0].name
    port          = local.mnemo_port

    priorityClassName = local.aether_priority_classes.app

    gateway = {
      host            = local.mnemo_host
      parentName      = "main-gateway"
      parentNamespace = "default"
    }

    resources = {
      requests = { cpu = "100m", memory = "1Gi" }
      limits   = { cpu = "1000m", memory = "1Gi" }
    }

    meili = {
      image               = "getmeili/meilisearch:v1.12"
      port                = 7700
      storageClass        = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
      storageSize         = "100Gi"
      masterKeySecretName = kubernetes_secret_v1.mnemo_env.metadata[0].name
      masterKeySecretKey  = "MEILI_MASTER_KEY"
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { cpu = "4000m", memory = "4Gi" }
      }
    }

    backfill = {
      enabled = true
      reset   = false
      resources = {
        requests = { cpu = "100m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "2Gi" }
      }
    }
  })]

  set = [
    { name = "image.tag", value = local.mnemo_image_tag }
  ]
}

# --- DB Backup Target --------------------------------------------------------

resource "kubectl_manifest" "mnemo_cnpg_backup" {
  depends_on = [kubectl_manifest.mnemo_cnpg_cluster, kubectl_manifest.cnpg_barman_object_store]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "mnemo-cnpg-backup"
      namespace = local.mnemo_namespace
    }
    spec = {
      schedule             = "0 0 2 * * *" # Daily at 02:00 UTC; CNPG schedules include seconds.
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
}
