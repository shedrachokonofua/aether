# =============================================================================
# Temporal
# =============================================================================
# Migrated from the legacy Podman-on-Dokku deployment when the Dokku VM
# was retired. Provides workflow orchestration for in-cluster workers.
#
# Stack:
#   * temporal-postgres: StatefulSet + PVC backing store (Ceph RBD)
#   * temporal-server: auto-setup image (handles schema migrations on boot)
#   * temporal-ui: web UI exposed via HTTPRoute at temporal.apps.home.shdr.ch
#                  (Caddy on the home gateway forwards temporal.home.shdr.ch
#                   to it).
#
# In-cluster gRPC clients connect to:
#   temporal-server.temporal.svc.cluster.local:7233
#
# External gRPC is not exposed — old Dokku deployment did, but workers
# all live in-cluster now so there's no consumer for it. Re-add a
# GRPCRoute later if a use case appears.

locals {
  temporal_namespace      = "temporal"
  temporal_host           = "temporal.apps.home.shdr.ch"
  temporal_image          = "docker.io/temporalio/auto-setup:latest"
  temporal_ui_image       = "docker.io/temporalio/ui:latest"
  temporal_postgres_image = "docker.io/postgres:17-alpine"
  temporal_pg_db          = "temporal"
  temporal_pg_user        = "temporal"
  temporal_pg_service     = "temporal-postgres"
  temporal_pg_port        = 5432
  temporal_dynamic_config = <<-YAML
    limit.maxIDLength:
      - value: 255
        constraints: {}
    system.forceSearchAttributesCacheRefreshOnRead:
      - value: true
        constraints: {}
  YAML
}

resource "kubernetes_namespace_v1" "temporal" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.temporal_namespace
  }
}

# ─── Postgres ────────────────────────────────────────────────────────────────

resource "random_password" "temporal_postgres_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "temporal_postgres" {
  depends_on = [kubernetes_namespace_v1.temporal]

  metadata {
    name      = "temporal-postgres"
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
  }

  data = {
    POSTGRES_DB       = local.temporal_pg_db
    POSTGRES_USER     = local.temporal_pg_user
    POSTGRES_PASSWORD = random_password.temporal_postgres_password.result
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "temporal_postgres_data" {
  depends_on = [kubernetes_namespace_v1.temporal, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "temporal-postgres-data"
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
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

resource "kubernetes_stateful_set_v1" "temporal_postgres" {
  depends_on = [kubernetes_secret_v1.temporal_postgres, kubernetes_persistent_volume_claim_v1.temporal_postgres_data]

  metadata {
    name      = local.temporal_pg_service
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
    labels    = { app = local.temporal_pg_service }
  }

  spec {
    service_name = local.temporal_pg_service
    replicas     = 1

    selector {
      match_labels = { app = local.temporal_pg_service }
    }

    template {
      metadata {
        labels = { app = local.temporal_pg_service }
      }

      spec {
        container {
          name  = "postgres"
          image = local.temporal_postgres_image

          port {
            container_port = local.temporal_pg_port
          }

          env_from {
            secret_ref { name = kubernetes_secret_v1.temporal_postgres.metadata[0].name }
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          readiness_probe {
            exec {
              command = ["/bin/sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            exec {
              command = ["/bin/sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1Gi" }
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.temporal_postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "temporal_postgres" {
  depends_on = [kubernetes_stateful_set_v1.temporal_postgres]

  metadata {
    name      = local.temporal_pg_service
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
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

# ─── Temporal server ─────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "temporal_dynamic_config" {
  depends_on = [kubernetes_namespace_v1.temporal]

  metadata {
    name      = "temporal-dynamic-config"
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
  }

  data = {
    "development-sql.yaml" = local.temporal_dynamic_config
  }
}

resource "kubernetes_deployment_v1" "temporal_server" {
  depends_on = [kubernetes_service_v1.temporal_postgres, kubernetes_config_map_v1.temporal_dynamic_config]

  metadata {
    name      = "temporal-server"
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
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
            value = "${local.temporal_pg_service}.${local.temporal_namespace}.svc.cluster.local"
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
            requests = { cpu = "200m", memory = "512Mi" }
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
}

resource "kubernetes_service_v1" "temporal_server" {
  depends_on = [kubernetes_deployment_v1.temporal_server]

  metadata {
    name      = "temporal-server"
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
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
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
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
            value = "https://temporal.home.shdr.ch,https://${local.temporal_host}"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "temporal_ui" {
  depends_on = [kubernetes_deployment_v1.temporal_ui]

  metadata {
    name      = "temporal-ui"
    namespace = kubernetes_namespace_v1.temporal.metadata[0].name
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
      namespace = kubernetes_namespace_v1.temporal.metadata[0].name
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
