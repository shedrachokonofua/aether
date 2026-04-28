# =============================================================================
# Your-Spotify — Spotify Listening Statistics
# =============================================================================
# Stack: API server + web client + MongoDB.
#
# Data migration: copy mongo_data docker volume from Dokploy VM.
#   Active volume: mongo_data-default-yourspotify-xirzmz (_data) → 530 MB
#   Orphan volume: mongo_data (301 MB old deploy) — skip.
#
# Spotify credentials: move from hardcoded compose to sops.
# Required sops keys:
#   yourspotify.spotify_public  (SPOTIFY_PUBLIC client ID)
#   yourspotify.spotify_secret  (SPOTIFY_SECRET client secret)

resource "kubernetes_namespace_v1" "yourspotify" {
  depends_on = [helm_release.cilium]
  metadata { name = "yourspotify" }
}

locals {
  yourspotify_api_image    = "yooooomi/your_spotify_server"
  yourspotify_client_image = "yooooomi/your_spotify_client"
  yourspotify_mongo_image  = "mongo:6"

  yourspotify_host     = "your-spotify.home.shdr.ch"
  yourspotify_api_host = "your-spotify-api.home.shdr.ch"

  yourspotify_client_port = 3000
  yourspotify_api_port    = 8080
  yourspotify_mongo_port  = 27017

  yourspotify_ns           = kubernetes_namespace_v1.yourspotify.metadata[0].name
  yourspotify_api_labels   = { app = "yourspotify-api" }
  yourspotify_client_labels = { app = "yourspotify-client" }
  yourspotify_mongo_labels  = { app = "yourspotify-mongo" }
}

resource "kubernetes_persistent_volume_claim_v1" "yourspotify_mongo_data" {
  depends_on = [kubernetes_namespace_v1.yourspotify, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "yourspotify-mongo-data"
    namespace = local.yourspotify_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }

  lifecycle { prevent_destroy = true }
}

# MongoDB
resource "kubernetes_stateful_set_v1" "yourspotify_mongo" {
  depends_on = [kubernetes_persistent_volume_claim_v1.yourspotify_mongo_data]

  metadata {
    name      = "yourspotify-mongo"
    namespace = local.yourspotify_ns
    labels    = local.yourspotify_mongo_labels
  }

  spec {
    service_name = "yourspotify-mongo"
    replicas     = 1

    selector { match_labels = local.yourspotify_mongo_labels }

    template {
      metadata { labels = local.yourspotify_mongo_labels }
      spec {
        container {
          name  = "mongo"
          image = local.yourspotify_mongo_image

          port { container_port = local.yourspotify_mongo_port }

          volume_mount {
            name       = "data"
            mount_path = "/data/db"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          readiness_probe {
            exec { command = ["mongosh", "--eval", "db.adminCommand('ping')"] }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.yourspotify_mongo_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "yourspotify_mongo" {
  depends_on = [kubernetes_stateful_set_v1.yourspotify_mongo]
  metadata {
    name      = "yourspotify-mongo"
    namespace = local.yourspotify_ns
    labels    = local.yourspotify_mongo_labels
  }
  spec {
    selector = local.yourspotify_mongo_labels
    port {
      port = local.yourspotify_mongo_port
      target_port = local.yourspotify_mongo_port
    }
    type = "ClusterIP"
  }
}

# API Server
resource "kubernetes_deployment_v1" "yourspotify_api" {
  depends_on = [kubernetes_service_v1.yourspotify_mongo]

  metadata {
    name      = "yourspotify-api"
    namespace = local.yourspotify_ns
    labels    = local.yourspotify_api_labels
  }

  spec {
    replicas = 1
    selector { match_labels = local.yourspotify_api_labels }

    template {
      metadata { labels = local.yourspotify_api_labels }
      spec {
        enable_service_links = false
        container {
          name  = "api"
          image = local.yourspotify_api_image

          env {
            name  = "API_ENDPOINT"
            value = "https://${local.yourspotify_api_host}"
          }
          env {
            name  = "CLIENT_ENDPOINT"
            value = "https://${local.yourspotify_host}"
          }
          env {
            name  = "SPOTIFY_PUBLIC"
            value = var.secrets["yourspotify.spotify_public"]
          }
          env {
            name  = "SPOTIFY_SECRET"
            value = var.secrets["yourspotify.spotify_secret"]
          }
          env {
            name  = "MONGO_ENDPOINT"
            value = "mongodb://yourspotify-mongo.${local.yourspotify_ns}.svc.cluster.local:${local.yourspotify_mongo_port}/your_spotify"
          }

          port {
            container_port = local.yourspotify_api_port
            name = "http"
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

resource "kubernetes_service_v1" "yourspotify_api" {
  metadata {
    name      = "yourspotify-api"
    namespace = local.yourspotify_ns
    labels    = local.yourspotify_api_labels
  }
  spec {
    selector = local.yourspotify_api_labels
    port {
      port = local.yourspotify_api_port
      target_port = local.yourspotify_api_port
      name = "http"
    }
  }
}

# Web Client
resource "kubernetes_deployment_v1" "yourspotify_client" {
  depends_on = [kubernetes_service_v1.yourspotify_api]

  metadata {
    name      = "yourspotify-client"
    namespace = local.yourspotify_ns
    labels    = local.yourspotify_client_labels
  }

  spec {
    replicas = 1
    selector { match_labels = local.yourspotify_client_labels }

    template {
      metadata { labels = local.yourspotify_client_labels }
      spec {
        enable_service_links = false
        container {
          name  = "client"
          image = local.yourspotify_client_image

          env {
            name  = "API_ENDPOINT"
            value = "https://${local.yourspotify_api_host}"
          }

          port {
            container_port = local.yourspotify_client_port
            name = "http"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "yourspotify_client" {
  metadata {
    name      = "yourspotify-client"
    namespace = local.yourspotify_ns
    labels    = local.yourspotify_client_labels
  }
  spec {
    selector = local.yourspotify_client_labels
    port {
      port = local.yourspotify_client_port
      target_port = local.yourspotify_client_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "yourspotify_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.yourspotify_client]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "yourspotify", namespace = local.yourspotify_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.yourspotify_host]
      rules      = [{ backendRefs = [{ name = "yourspotify-client", port = local.yourspotify_client_port }] }]
    }
  }
}

resource "kubernetes_manifest" "yourspotify_api_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.yourspotify_api]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "yourspotify-api", namespace = local.yourspotify_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.yourspotify_api_host]
      rules      = [{ backendRefs = [{ name = "yourspotify-api", port = local.yourspotify_api_port }] }]
    }
  }
}
