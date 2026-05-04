# =============================================================================
# StremThru — Stremio debrid resolver / list-syncer
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Single SQLite DB (stremthru.db) on a small ceph-rbd PVC.

locals {
  stremthru_image  = "docker.io/muniftanjim/stremthru:latest"
  stremthru_host   = "stremthru.home.shdr.ch"
  stremthru_port   = 8080
  stremthru_ns     = local.jellyfin_ns
  stremthru_labels = { app = "stremthru" }
}

# =============================================================================
# Secret
# =============================================================================

resource "kubernetes_secret_v1" "stremthru" {
  depends_on = [kubernetes_namespace_v1.media]

  metadata {
    name      = "stremthru"
    namespace = local.stremthru_ns
  }

  type = "Opaque"

  data = {
    # Multi-store auth string consumed by stremthru.
    store_auth = "*:realdebrid:${var.secrets["stremthru.realdebrid_api_token"]},*:premiumize:${var.secrets["stremthru.premiumize_api_key"]}"
  }
}

# =============================================================================
# PVC (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "stremthru_data" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "stremthru-data"
    namespace = local.stremthru_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    # Stremthru caches months of IMDB syncs, DMM hashlists, and letterboxd
    # lists — VM data dir is currently ~3.6 GB. Sizing for headroom.
    resources {
      requests = { storage = "10Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "stremthru" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.stremthru_data,
    kubernetes_secret_v1.stremthru,
  ]

  metadata {
    name      = "stremthru"
    namespace = local.stremthru_ns
    labels    = local.stremthru_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.stremthru_labels
    }

    template {
      metadata {
        labels = local.stremthru_labels
      }

      spec {
        # K8s injects $STREMTHRU_PORT=tcp://<svc-ip>:8080 from the same-named
        # Service, which stremthru's own port-config env var collides with
        # ("too many colons in address"). Turn off the legacy service-link
        # env injection.
        enable_service_links = false

        container {
          name  = "stremthru"
          image = local.stremthru_image

          port {
            container_port = local.stremthru_port
            name           = "http"
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          env {
            name  = "STREMTHRU_DATABASE_URI"
            value = "sqlite://./data/stremthru.db"
          }

          env {
            name = "STREMTHRU_STORE_AUTH"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.stremthru.metadata[0].name
                key  = "store_auth"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.stremthru_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = local.stremthru_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.stremthru_data.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "stremthru" {
  metadata {
    name      = "stremthru"
    namespace = local.stremthru_ns
    labels    = local.stremthru_labels
  }

  spec {
    selector = local.stremthru_labels

    port {
      port        = local.stremthru_port
      target_port = local.stremthru_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "stremthru_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.stremthru]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "stremthru"
      namespace = local.stremthru_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.stremthru_host]
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
          name = kubernetes_service_v1.stremthru.metadata[0].name
          port = local.stremthru_port
        }]
      }]
    }
  }
}
