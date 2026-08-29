# =============================================================================
# AIOMetadata — metadata provider for media clients
# =============================================================================
# Runs the application and its Redis sidecar against one shared Ceph RBD PVC.

locals {
  aiometadata_image  = "ghcr.io/cedya77/aiometadata@sha256:ef01baa501ac228e7024553842d48108b87620a03160797105143519e0ed43e9"
  aiometadata_host   = "aiometadata.home.shdr.ch"
  aiometadata_port   = 3232
  aiometadata_ns     = local.media_ns
  aiometadata_labels = { app = "aiometadata" }
}

# =============================================================================
# Secret
# =============================================================================

resource "kubernetes_secret_v1" "aiometadata" {
  depends_on = [module.namespace["media"]]

  metadata {
    name      = "aiometadata"
    namespace = local.aiometadata_ns
  }

  type = "Opaque"

  data = {
    tmdb_api_key               = var.secrets["tmdb_api_key"]
    tvdb_api_key               = var.secrets["aiostreams.tvdb_api_key"]
    admin_key                  = var.secrets["aiometadata.admin_key"]
    image_proxy_signing_secret = var.secrets["aiometadata.image_proxy_signing_secret"]
  }
}

# =============================================================================
# PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "aiometadata_data" {
  depends_on = [module.namespace["media"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "aiometadata-data"
    namespace = local.aiometadata_ns
    labels    = local.aiometadata_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "aiometadata" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.aiometadata_data,
    kubernetes_secret_v1.aiometadata,
  ]

  metadata {
    name      = "aiometadata"
    namespace = local.aiometadata_ns
    labels    = local.aiometadata_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.aiometadata_labels
    }

    template {
      metadata {
        labels = local.aiometadata_labels
      }

      spec {
        container {
          name  = "aiometadata"
          image = local.aiometadata_image

          port {
            container_port = local.aiometadata_port
            name           = "http"
          }

          env {
            name  = "PORT"
            value = tostring(local.aiometadata_port)
          }

          env {
            name  = "HOST_NAME"
            value = "https://${local.aiometadata_host}"
          }

          env {
            name  = "NODE_ENV"
            value = "production"
          }

          env {
            name  = "LOG_LEVEL"
            value = "info"
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          env {
            name  = "DATABASE_URI"
            value = "sqlite://addon/data/db.sqlite"
          }

          env {
            name  = "REDIS_URL"
            value = "redis://127.0.0.1:6379"
          }

          env {
            name  = "DISABLE_TRAKT_SEARCH"
            value = "true"
          }

          env {
            name  = "POSTER_PROXY_ALLOW_PRIVATE"
            value = "false"
          }

          env {
            name = "TMDB_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiometadata.metadata[0].name
                key  = "tmdb_api_key"
              }
            }
          }

          env {
            name = "BUILT_IN_TMDB_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiometadata.metadata[0].name
                key  = "tmdb_api_key"
              }
            }
          }

          env {
            name = "TVDB_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiometadata.metadata[0].name
                key  = "tvdb_api_key"
              }
            }
          }

          env {
            name = "BUILT_IN_TVDB_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiometadata.metadata[0].name
                key  = "tvdb_api_key"
              }
            }
          }

          env {
            name = "ADMIN_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiometadata.metadata[0].name
                key  = "admin_key"
              }
            }
          }

          env {
            name = "IMAGE_PROXY_SIGNING_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiometadata.metadata[0].name
                key  = "image_proxy_signing_secret"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/addon/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health/live"
              port = local.aiometadata_port
            }
            period_seconds  = 30
            timeout_seconds = 3
          }

          readiness_probe {
            http_get {
              path = "/health/ready"
              port = local.aiometadata_port
            }
            period_seconds  = 10
            timeout_seconds = 3
          }

          startup_probe {
            http_get {
              path = "/health/live"
              port = local.aiometadata_port
            }
            failure_threshold = 30
            period_seconds    = 2
            timeout_seconds   = 2
          }
        }

        container {
          name  = "redis"
          image = "redis:7.4.2-alpine"

          command = ["redis-server"]
          args    = ["--appendonly", "yes", "--save", "3600", "1", "--dir", "/data"]

          port {
            container_port = 6379
            name           = "redis"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = 6379
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = 6379
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.aiometadata_data.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "aiometadata" {
  metadata {
    name      = "aiometadata"
    namespace = local.aiometadata_ns
    labels    = local.aiometadata_labels
  }

  spec {
    selector = local.aiometadata_labels

    port {
      port        = local.aiometadata_port
      target_port = local.aiometadata_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "aiometadata_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.aiometadata]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "aiometadata"
      namespace = local.aiometadata_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.aiometadata_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.aiometadata.metadata[0].name
          port = local.aiometadata_port
        }]
      }]
    }
  }
}
