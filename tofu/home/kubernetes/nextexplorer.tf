# =============================================================================
# nextExplorer — file browser for the media library
# =============================================================================
# Replaces filestash on the media-stack VM. Single Express + SQLite app
# that browses arbitrary mounted directories. Wired to Keycloak OIDC and
# the existing media-hdd NFS PVC so users can browse the library through
# files.home.shdr.ch with their normal SSO.

locals {
  nextexplorer_image     = "docker.io/nxzai/explorer:latest"
  nextexplorer_host      = "files.home.shdr.ch"
  nextexplorer_port      = 3000
  nextexplorer_ns        = local.jellyfin_ns
  nextexplorer_labels    = { app = "nextexplorer" }
  nextexplorer_oidc_url  = var.oidc_issuer_url
  nextexplorer_public    = "https://${local.nextexplorer_host}"
}

# =============================================================================
# Random session secret (≥32 chars, stable across restarts)
# =============================================================================

resource "random_password" "nextexplorer_session" {
  length  = 64
  special = false
}

# =============================================================================
# Secret
# =============================================================================

resource "kubernetes_secret_v1" "nextexplorer" {
  depends_on = [kubernetes_namespace_v1.media]

  metadata {
    name      = "nextexplorer"
    namespace = local.nextexplorer_ns
  }

  type = "Opaque"

  data = {
    session_secret      = random_password.nextexplorer_session.result
    oidc_client_secret  = var.nextexplorer_oauth_client_secret
  }
}

# =============================================================================
# PVCs (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "nextexplorer_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nextexplorer-config"
    namespace = local.nextexplorer_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "1Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "nextexplorer_cache" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "nextexplorer-cache"
    namespace = local.nextexplorer_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "10Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "nextexplorer" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.nextexplorer_config,
    kubernetes_persistent_volume_claim_v1.nextexplorer_cache,
    kubernetes_persistent_volume_claim_v1.media_hdd,
    kubernetes_secret_v1.nextexplorer,
  ]

  metadata {
    name      = "nextexplorer"
    namespace = local.nextexplorer_ns
    labels    = local.nextexplorer_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.nextexplorer_labels
    }

    template {
      metadata {
        labels = local.nextexplorer_labels
      }

      spec {
        container {
          name  = "nextexplorer"
          image = local.nextexplorer_image

          port {
            container_port = local.nextexplorer_port
            name           = "http"
          }

          env {
            name  = "NODE_ENV"
            value = "production"
          }

          env {
            name  = "PORT"
            value = tostring(local.nextexplorer_port)
          }

          env {
            name  = "PUBLIC_URL"
            value = local.nextexplorer_public
          }

          env {
            name  = "AUTH_MODE"
            value = "both"
          }

          env {
            name  = "OIDC_ENABLED"
            value = "true"
          }

          env {
            name  = "OIDC_AUTO_CREATE_USERS"
            value = "true"
          }

          env {
            name  = "OIDC_SCOPES"
            value = "openid profile email"
          }

          env {
            name  = "OIDC_ISSUER"
            value = local.nextexplorer_oidc_url
          }

          env {
            name  = "OIDC_CLIENT_ID"
            value = "nextexplorer"
          }

          env {
            name = "OIDC_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.nextexplorer.metadata[0].name
                key  = "oidc_client_secret"
              }
            }
          }

          env {
            name  = "OIDC_CALLBACK_URL"
            value = "${local.nextexplorer_public}/callback"
          }

          env {
            name = "SESSION_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.nextexplorer.metadata[0].name
                key  = "session_secret"
              }
            }
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }

          volume_mount {
            name       = "media"
            mount_path = "/mnt/Media"
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
              port = local.nextexplorer_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.nextexplorer_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextexplorer_config.metadata[0].name
          }
        }

        volume {
          name = "cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextexplorer_cache.metadata[0].name
          }
        }

        volume {
          name = "media"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.media_hdd.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "nextexplorer" {
  metadata {
    name      = "nextexplorer"
    namespace = local.nextexplorer_ns
    labels    = local.nextexplorer_labels
  }

  spec {
    selector = local.nextexplorer_labels

    port {
      port        = local.nextexplorer_port
      target_port = local.nextexplorer_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "nextexplorer_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.nextexplorer]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "nextexplorer"
      namespace = local.nextexplorer_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.nextexplorer_host]
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
          name = kubernetes_service_v1.nextexplorer.metadata[0].name
          port = local.nextexplorer_port
        }]
      }]
    }
  }
}
