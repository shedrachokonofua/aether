# =============================================================================
# Miniflux — RSS reader
# =============================================================================
# Postgres-backed RSS reader, wired to Keycloak OIDC for daily login. A local
# admin account is bootstrapped from a generated password as a break-glass for
# Keycloak outages. OAUTH2_USER_CREATION=1 lets first OIDC login auto-create
# a user; the realm is private so that's safe.

resource "kubernetes_namespace_v1" "miniflux" {
  depends_on = [helm_release.cilium]
  metadata {
    name = "miniflux"
    labels = {
      "goldilocks.fairwinds.com/enabled" = "true"
    }
  }
}

resource "random_password" "miniflux_postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "miniflux_admin_password" {
  length  = 32
  special = false
}

locals {
  miniflux_image          = "miniflux/miniflux:latest"
  miniflux_postgres_image = "postgres:17-alpine"

  miniflux_host    = "miniflux.home.shdr.ch"
  miniflux_port    = 8080
  miniflux_pg_port = 5432

  miniflux_ns        = kubernetes_namespace_v1.miniflux.metadata[0].name
  miniflux_labels    = { app = "miniflux" }
  miniflux_pg_labels = { app = "miniflux-postgres" }

  miniflux_db_url = "postgres://miniflux:${random_password.miniflux_postgres_password.result}@miniflux-postgres.${local.miniflux_ns}.svc.cluster.local:${local.miniflux_pg_port}/miniflux?sslmode=disable"
}

# =============================================================================
# Secrets
# =============================================================================

resource "kubernetes_secret_v1" "miniflux_postgres" {
  depends_on = [kubernetes_namespace_v1.miniflux]
  metadata {
    name      = "miniflux-postgres"
    namespace = local.miniflux_ns
  }
  type = "Opaque"
  data = {
    POSTGRES_PASSWORD = random_password.miniflux_postgres_password.result
    POSTGRES_USER     = "miniflux"
    POSTGRES_DB       = "miniflux"
  }
}

resource "kubernetes_secret_v1" "miniflux" {
  depends_on = [kubernetes_namespace_v1.miniflux]
  metadata {
    name      = "miniflux"
    namespace = local.miniflux_ns
  }
  type = "Opaque"
  data = {
    DATABASE_URL         = local.miniflux_db_url
    ADMIN_PASSWORD       = random_password.miniflux_admin_password.result
    OAUTH2_CLIENT_SECRET = var.miniflux_oauth_client_secret
  }
}

# =============================================================================
# Postgres — StatefulSet + Service
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "miniflux_postgres_data" {
  depends_on = [kubernetes_namespace_v1.miniflux, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name      = "miniflux-postgres-data"
    namespace = local.miniflux_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_stateful_set_v1" "miniflux_postgres" {
  depends_on = [kubernetes_secret_v1.miniflux_postgres, kubernetes_persistent_volume_claim_v1.miniflux_postgres_data]
  metadata {
    name      = "miniflux-postgres"
    namespace = local.miniflux_ns
    labels    = local.miniflux_pg_labels
  }
  spec {
    service_name = "miniflux-postgres"
    replicas     = 1
    selector { match_labels = local.miniflux_pg_labels }
    template {
      metadata { labels = local.miniflux_pg_labels }
      spec {
        container {
          name  = "postgres"
          image = local.miniflux_postgres_image
          env_from {
            secret_ref { name = kubernetes_secret_v1.miniflux_postgres.metadata[0].name }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port { container_port = local.miniflux_pg_port }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          readiness_probe {
            exec { command = ["/bin/sh", "-c", "pg_isready -U miniflux -d miniflux"] }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.miniflux_postgres_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "miniflux_postgres" {
  depends_on = [kubernetes_stateful_set_v1.miniflux_postgres]
  metadata {
    name      = "miniflux-postgres"
    namespace = local.miniflux_ns
    labels    = local.miniflux_pg_labels
  }
  spec {
    selector = local.miniflux_pg_labels
    port {
      port        = local.miniflux_pg_port
      target_port = local.miniflux_pg_port
    }
    type = "ClusterIP"
  }
}

# =============================================================================
# Miniflux app
# =============================================================================

resource "kubernetes_deployment_v1" "miniflux" {
  depends_on = [
    kubernetes_service_v1.miniflux_postgres,
    kubernetes_secret_v1.miniflux,
  ]

  metadata {
    name      = "miniflux"
    namespace = local.miniflux_ns
    labels    = local.miniflux_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector { match_labels = local.miniflux_labels }

    template {
      metadata { labels = local.miniflux_labels }

      spec {
        container {
          name  = "miniflux"
          image = local.miniflux_image

          env_from {
            secret_ref { name = kubernetes_secret_v1.miniflux.metadata[0].name }
          }

          env {
            name  = "LISTEN_ADDR"
            value = ":${local.miniflux_port}"
          }
          env {
            name  = "BASE_URL"
            value = "https://${local.miniflux_host}"
          }
          env {
            name  = "HTTPS"
            value = "1"
          }
          env {
            name  = "RUN_MIGRATIONS"
            value = "1"
          }
          env {
            name  = "CREATE_ADMIN"
            value = "1"
          }
          env {
            name  = "ADMIN_USERNAME"
            value = "shedrach"
          }

          # OIDC
          env {
            name  = "OAUTH2_PROVIDER"
            value = "oidc"
          }
          env {
            name  = "OAUTH2_CLIENT_ID"
            value = "miniflux"
          }
          env {
            name  = "OAUTH2_REDIRECT_URL"
            value = "https://${local.miniflux_host}/oauth2/oidc/callback"
          }
          env {
            name  = "OAUTH2_OIDC_DISCOVERY_ENDPOINT"
            value = var.oidc_issuer_url
          }
          env {
            name  = "OAUTH2_OIDC_PROVIDER_NAME"
            value = "Keycloak"
          }
          env {
            name  = "OAUTH2_USER_CREATION"
            value = "1"
          }

          port {
            container_port = local.miniflux_port
            name           = "http"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = local.miniflux_port
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = local.miniflux_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "miniflux" {
  metadata {
    name      = "miniflux"
    namespace = local.miniflux_ns
    labels    = local.miniflux_labels
  }
  spec {
    selector = local.miniflux_labels
    port {
      port        = local.miniflux_port
      target_port = local.miniflux_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "miniflux_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.miniflux]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "miniflux", namespace = local.miniflux_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.miniflux_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "miniflux", port = local.miniflux_port }]
      }]
    }
  }
}
