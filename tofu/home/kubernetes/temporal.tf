# =============================================================================
# Temporal
# =============================================================================
# Migrated from the legacy Podman-on-Dokku deployment when the Dokku VM
# was retired. Provides workflow orchestration for in-cluster workers.
#
# Stack:
#   * temporal-postgres: StatefulSet + PVC backing store (Ceph RBD)
#   * temporal-server: auto-setup image (handles schema migrations on boot)
#   * temporal-ui: web UI exposed via HTTPRoute at temporal.home.shdr.ch
#                  (Caddy on the home gateway forwards traffic to the k8s
#                   gateway VIP preserving the Host header).
#
# In-cluster gRPC clients connect to:
#   temporal-server.temporal.svc.cluster.local:7233
#
# External gRPC is not exposed — old Dokku deployment did, but workers
# all live in-cluster now so there's no consumer for it. Re-add a
# GRPCRoute later if a use case appears.

locals {
  temporal_namespace      = "temporal"
  temporal_host           = "temporal.home.shdr.ch"
  temporal_image          = "docker.io/temporalio/auto-setup:latest"
  temporal_ui_image       = "docker.io/temporalio/ui:latest"
  temporal_postgres_image = "docker.io/postgres:17-alpine"
  temporal_pg_db          = "temporal"
  temporal_pg_user        = "temporal"
  temporal_pg_service     = "temporal-postgres"
  temporal_pg_port        = 5432
  temporal_cnpg_cluster   = "temporal-cnpg"
  temporal_pg_host        = "${local.temporal_cnpg_cluster}-rw.${local.temporal_namespace}.svc.cluster.local"
  temporal_dynamic_config = <<-YAML
    limit.maxIDLength:
      - value: 255
        constraints: {}
    system.forceSearchAttributesCacheRefreshOnRead:
      - value: true
        constraints: {}
  YAML
}


# ─── Postgres ────────────────────────────────────────────────────────────────

resource "random_password" "temporal_postgres_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "temporal_postgres" {
  depends_on = [module.namespace["temporal"]]

  metadata {
    name      = "temporal-postgres"
    namespace = module.namespace["temporal"].name
  }

  data = {
    POSTGRES_DB       = local.temporal_pg_db
    POSTGRES_USER     = local.temporal_pg_user
    POSTGRES_PASSWORD = random_password.temporal_postgres_password.result
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "temporal_cnpg_app" {
  depends_on = [module.namespace["temporal"]]

  metadata {
    name      = "temporal-cnpg-app"
    namespace = module.namespace["temporal"].name
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.temporal_pg_user
    password = random_password.temporal_postgres_password.result
  }
}

resource "kubernetes_persistent_volume_claim_v1" "temporal_postgres_data" {
  depends_on = [module.namespace["temporal"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "temporal-postgres-data"
    namespace = module.namespace["temporal"].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

resource "kubernetes_service_v1" "temporal_postgres" {

  metadata {
    name      = local.temporal_pg_service
    namespace = module.namespace["temporal"].name
    labels    = { app = local.temporal_pg_service }
  }

  spec {
    selector = { app = local.temporal_pg_service }

    port {
      port        = local.temporal_pg_port
      target_port = local.temporal_pg_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubectl_manifest" "temporal_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.temporal_cnpg_app,
    kubernetes_service_v1.temporal_postgres,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.temporal_cnpg_cluster
      namespace = module.namespace["temporal"].name
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:17.9"
      storage = {
        size         = "20Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["temporal"]
      bootstrap = {
        initdb = {
          database = local.temporal_pg_db
          owner    = local.temporal_pg_user
          secret = {
            name = kubernetes_secret_v1.temporal_cnpg_app.metadata[0].name
          }
          import = {
            type      = "microservice"
            databases = [local.temporal_pg_db]
            source = {
              externalCluster = "temporal-source"
            }
            postImportApplicationSQL = [
              "ALTER ROLE ${local.temporal_pg_user} CREATEDB",
            ]
          }
        }
      }
      externalClusters = [{
        name = "temporal-source"
        connectionParameters = {
          host    = "${local.temporal_pg_service}.${local.temporal_namespace}.svc.cluster.local"
          user    = local.temporal_pg_user
          dbname  = local.temporal_pg_db
          sslmode = "disable"
        }
        password = {
          name = kubernetes_secret_v1.temporal_postgres.metadata[0].name
          key  = "POSTGRES_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_job_v1" "temporal_visibility_import" {
  depends_on = [kubectl_manifest.temporal_cnpg_cluster]

  metadata {
    name      = "temporal-visibility-import"
    namespace = module.namespace["temporal"].name
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          app = "temporal-visibility-import"
        }
      }

      spec {
        restart_policy       = "OnFailure"
        enable_service_links = false

        container {
          name  = "import"
          image = local.db_backup_pg_image

          command = ["/bin/sh", "-ec", <<-EOT
            set -eu

            export PGPASSWORD="$DST_PGPASSWORD"
            if psql -h "$DST_PGHOST" -p "$PGPORT" -U "$DST_PGUSER" -d postgres -Atc "select 1 from pg_database where datname = 'temporal_visibility'" | grep -qx 1; then
              tables="$(psql -h "$DST_PGHOST" -p "$PGPORT" -U "$DST_PGUSER" -d temporal_visibility -Atc "select count(*) from information_schema.tables where table_schema = 'public'")"
              if [ "$tables" != "0" ]; then
                echo "temporal_visibility already restored"
                exit 0
              fi
            else
              createdb -h "$DST_PGHOST" -p "$PGPORT" -U "$DST_PGUSER" temporal_visibility
            fi

            export PGPASSWORD="$SRC_PGPASSWORD"
            pg_dump -h "$SRC_PGHOST" -p "$PGPORT" -U "$SRC_PGUSER" -d temporal_visibility --format=custom --file /tmp/temporal_visibility.dump

            export PGPASSWORD="$DST_PGPASSWORD"
            pg_restore -h "$DST_PGHOST" -p "$PGPORT" -U "$DST_PGUSER" -d temporal_visibility --no-owner --role="$DST_PGUSER" /tmp/temporal_visibility.dump
          EOT
          ]

          env {
            name  = "SRC_PGHOST"
            value = "${local.temporal_pg_service}.${local.temporal_namespace}.svc.cluster.local"
          }
          env {
            name = "SRC_PGUSER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.temporal_postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }
          env {
            name = "SRC_PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.temporal_postgres.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name  = "DST_PGHOST"
            value = local.temporal_pg_host
          }
          env {
            name = "DST_PGUSER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.temporal_cnpg_app.metadata[0].name
                key  = "username"
              }
            }
          }
          env {
            name = "DST_PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.temporal_cnpg_app.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name  = "PGPORT"
            value = tostring(local.temporal_pg_port)
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
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

# ─── Temporal server ─────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "temporal_dynamic_config" {
  depends_on = [module.namespace["temporal"]]

  metadata {
    name      = "temporal-dynamic-config"
    namespace = module.namespace["temporal"].name
  }

  data = {
    "development-sql.yaml" = local.temporal_dynamic_config
  }
}

resource "kubernetes_deployment_v1" "temporal_server" {
  depends_on = [kubernetes_job_v1.temporal_visibility_import, kubernetes_config_map_v1.temporal_dynamic_config]

  metadata {
    name      = "temporal-server"
    namespace = module.namespace["temporal"].name
    labels    = { app = "temporal-server" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "temporal-server" }
    }

    template {
      metadata {
        labels = { app = "temporal-server" }
      }

      spec {
        container {
          name              = "temporal-server"
          image             = local.temporal_image
          image_pull_policy = "Always"

          port {
            container_port = 7233
            name           = "grpc"
          }
          port {
            container_port = 7234
            name           = "membership"
          }

          env {
            name  = "DB"
            value = "postgres12"
          }
          env {
            name  = "DB_PORT"
            value = tostring(local.temporal_pg_port)
          }
          env {
            name  = "POSTGRES_SEEDS"
            value = local.temporal_pg_host
          }
          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.temporal_postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }
          env {
            name = "POSTGRES_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.temporal_postgres.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name  = "DYNAMIC_CONFIG_FILE_PATH"
            value = "/etc/temporal/config/dynamicconfig/development-sql.yaml"
          }
          env {
            name  = "BIND_ON_IP"
            value = "0.0.0.0"
          }

          volume_mount {
            name       = "dynamic-config"
            mount_path = "/etc/temporal/config/dynamicconfig"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "2000m", memory = "2Gi" }
          }

          readiness_probe {
            tcp_socket { port = 7233 }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "dynamic-config"
          config_map {
            name = kubernetes_config_map_v1.temporal_dynamic_config.metadata[0].name
          }
        }
      }
    }
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

resource "kubernetes_service_v1" "temporal_server" {
  depends_on = [kubernetes_deployment_v1.temporal_server]

  metadata {
    name      = "temporal-server"
    namespace = module.namespace["temporal"].name
    labels    = { app = "temporal-server" }
  }

  spec {
    selector = { app = "temporal-server" }

    port {
      name        = "grpc"
      port        = 7233
      target_port = 7233
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# ─── Temporal UI ─────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "temporal_ui" {
  depends_on = [kubernetes_service_v1.temporal_server]

  metadata {
    name      = "temporal-ui"
    namespace = module.namespace["temporal"].name
    labels    = { app = "temporal-ui" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "temporal-ui" }
    }

    template {
      metadata {
        labels = { app = "temporal-ui" }
      }

      spec {
        # The Service named `temporal-server` in this namespace causes kubelet
        # to inject `TEMPORAL_SERVER_PORT=tcp://...` into every pod here. The
        # temporal-ui image references that var via its config template and
        # tries to parse it as an int port, which fails YAML unmarshal. Disable
        # the legacy service-link env injection.
        enable_service_links = false

        container {
          name              = "temporal-ui"
          image             = local.temporal_ui_image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "TEMPORAL_ADDRESS"
            value = "${kubernetes_service_v1.temporal_server.metadata[0].name}.${local.temporal_namespace}.svc.cluster.local:7233"
          }
          env {
            name  = "TEMPORAL_CORS_ORIGINS"
            value = "https://${local.temporal_host}"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

resource "kubernetes_service_v1" "temporal_ui" {
  depends_on = [kubernetes_deployment_v1.temporal_ui]

  metadata {
    name      = "temporal-ui"
    namespace = module.namespace["temporal"].name
    labels    = { app = "temporal-ui" }
  }

  spec {
    selector = { app = "temporal-ui" }

    port {
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_manifest" "temporal_ui_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.temporal_ui]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "temporal-ui"
      namespace = module.namespace["temporal"].name
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.temporal_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.temporal_ui.metadata[0].name
          port = 8080
        }]
      }]
    }
  }
}
