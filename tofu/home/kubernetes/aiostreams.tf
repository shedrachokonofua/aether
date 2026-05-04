# =============================================================================
# AIOStreams — Stremio addon aggregator
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Talks to stremthru in-cluster via the Service hostname.

locals {
  aiostreams_image  = "ghcr.io/viren070/aiostreams:latest"
  aiostreams_host   = "aiostreams.home.shdr.ch"
  aiostreams_port   = 3000
  aiostreams_ns     = local.jellyfin_ns
  aiostreams_labels = { app = "aiostreams" }
}

# =============================================================================
# Secret
# =============================================================================

resource "kubernetes_secret_v1" "aiostreams" {
  depends_on = [kubernetes_namespace_v1.media]

  metadata {
    name      = "aiostreams"
    namespace = local.aiostreams_ns
  }

  type = "Opaque"

  data = {
    secret_key       = var.secrets["aiostreams.secret_key"]
    realdebrid_token = var.secrets["stremthru.realdebrid_api_token"]
    premiumize_key   = var.secrets["stremthru.premiumize_api_key"]
  }
}

# =============================================================================
# PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "aiostreams_data" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "aiostreams-data"
    namespace = local.aiostreams_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "2Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "aiostreams" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.aiostreams_data,
    kubernetes_secret_v1.aiostreams,
    kubernetes_service_v1.stremthru,
  ]

  metadata {
    name      = "aiostreams"
    namespace = local.aiostreams_ns
    labels    = local.aiostreams_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.aiostreams_labels
    }

    template {
      metadata {
        labels = local.aiostreams_labels
      }

      spec {
        container {
          name  = "aiostreams"
          image = local.aiostreams_image

          port {
            container_port = local.aiostreams_port
            name           = "http"
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          env {
            name  = "BASE_URL"
            value = "https://${local.aiostreams_host}"
          }

          env {
            name  = "DATABASE_URI"
            value = "sqlite://./data/db.sqlite"
          }

          env {
            name  = "BUILTIN_STREMTHRU_URL"
            value = "http://${kubernetes_service_v1.stremthru.metadata[0].name}.${local.aiostreams_ns}.svc.cluster.local:${local.stremthru_port}"
          }

          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiostreams.metadata[0].name
                key  = "secret_key"
              }
            }
          }

          env {
            name = "DEFAULT_REALDEBRID_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiostreams.metadata[0].name
                key  = "realdebrid_token"
              }
            }
          }

          env {
            name = "DEFAULT_PREMIUMIZE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.aiostreams.metadata[0].name
                key  = "premiumize_key"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "2"
              memory = "1Gi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.aiostreams_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = local.aiostreams_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.aiostreams_data.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "aiostreams" {
  metadata {
    name      = "aiostreams"
    namespace = local.aiostreams_ns
    labels    = local.aiostreams_labels
  }

  spec {
    selector = local.aiostreams_labels

    port {
      port        = local.aiostreams_port
      target_port = local.aiostreams_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "aiostreams_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.aiostreams]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "aiostreams"
      namespace = local.aiostreams_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.aiostreams_host]
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
          name = kubernetes_service_v1.aiostreams.metadata[0].name
          port = local.aiostreams_port
        }]
      }]
    }
  }
}
