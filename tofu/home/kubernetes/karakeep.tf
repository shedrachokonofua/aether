# =============================================================================
# Karakeep — Bookmark Manager (formerly Hoarder)
# =============================================================================
# Stack: main app + headless Chrome (for previews) + Meilisearch.
#
# Data migration:
#   data-default-hoarder-xlt9m2 (_data/karakeep.db sqlite) → karakeep-data PVC
#   meilisearch-default-hoarder-xlt9m2 → karakeep-meilisearch PVC
#
# Settings fix: OPENAI_BASE_URL was pointing at litellm.d.home.shdr.ch
# (a Dokploy service now dead). Updated to litellm.home.shdr.ch below.
#
# Required sops keys:
#   karakeep.nextauth_secret   (NEXTAUTH_SECRET — 32+ char random string)
#   karakeep.meili_master_key  (MEILI_MASTER_KEY — 32+ char random string)
#   litellm.virtual_keys.karakeep (OPENAI_API_KEY for LiteLLM)

resource "kubernetes_namespace_v1" "karakeep" {
  depends_on = [helm_release.cilium]
  metadata { name = "karakeep" }
}

resource "random_password" "karakeep_nextauth_secret" {
  length  = 32
  special = false
}

resource "random_password" "karakeep_meili_master_key" {
  length  = 32
  special = false
}

locals {
  karakeep_image    = "ghcr.io/karakeep-app/karakeep:release"
  karakeep_chrome_image   = "gcr.io/zenika-hub/alpine-chrome:123"
  karakeep_meili_image    = "getmeili/meilisearch:v1.13.3"

  karakeep_gateway_host = "karakeep.apps.home.shdr.ch"
  karakeep_host         = "karakeep.home.shdr.ch"

  karakeep_port       = 3000
  karakeep_chrome_port = 9222
  karakeep_meili_port  = 7700

  karakeep_ns           = kubernetes_namespace_v1.karakeep.metadata[0].name
  karakeep_labels       = { app = "karakeep" }
  karakeep_chrome_labels = { app = "karakeep-chrome" }
  karakeep_meili_labels  = { app = "karakeep-meilisearch" }
}

resource "kubernetes_persistent_volume_claim_v1" "karakeep_data" {
  depends_on = [kubernetes_namespace_v1.karakeep, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "karakeep-data"
    namespace = local.karakeep_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "10Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_persistent_volume_claim_v1" "karakeep_meilisearch" {
  depends_on = [kubernetes_namespace_v1.karakeep, kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name = "karakeep-meilisearch"
    namespace = local.karakeep_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
  lifecycle { prevent_destroy = true }
}

# Meilisearch
resource "kubernetes_deployment_v1" "karakeep_meilisearch" {
  depends_on = [kubernetes_persistent_volume_claim_v1.karakeep_meilisearch]
  metadata {
    name      = "karakeep-meilisearch"
    namespace = local.karakeep_ns
    labels    = local.karakeep_meili_labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = local.karakeep_meili_labels }
    template {
      metadata { labels = local.karakeep_meili_labels }
      spec {
        enable_service_links = false
        container {
          name  = "meilisearch"
          image = local.karakeep_meili_image
          env {
            name = "MEILI_MASTER_KEY"
            value = random_password.karakeep_meili_master_key.result
          }
          env {
            name = "MEILI_NO_ANALYTICS"
            value = "true"
          }
          port { container_port = local.karakeep_meili_port }
          volume_mount {
            name = "data"
            mount_path = "/meili_data"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = local.karakeep_meili_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.karakeep_meilisearch.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "karakeep_meilisearch" {
  metadata {
    name      = "karakeep-meilisearch"
    namespace = local.karakeep_ns
    labels    = local.karakeep_meili_labels
  }
  spec {
    selector = local.karakeep_meili_labels
    port {
      port = local.karakeep_meili_port
      target_port = local.karakeep_meili_port
    }
  }
}

# Headless Chrome for link previews
resource "kubernetes_deployment_v1" "karakeep_chrome" {
  depends_on = [kubernetes_namespace_v1.karakeep]
  metadata {
    name      = "karakeep-chrome"
    namespace = local.karakeep_ns
    labels    = local.karakeep_chrome_labels
  }
  spec {
    replicas = 1
    selector { match_labels = local.karakeep_chrome_labels }
    template {
      metadata { labels = local.karakeep_chrome_labels }
      spec {
        enable_service_links = false
        container {
          name    = "chrome"
          image   = local.karakeep_chrome_image
          command = [
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--remote-debugging-address=0.0.0.0",
            "--remote-debugging-port=${local.karakeep_chrome_port}",
            "--hide-scrollbars",
          ]
          port { container_port = local.karakeep_chrome_port }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "karakeep_chrome" {
  metadata {
    name      = "karakeep-chrome"
    namespace = local.karakeep_ns
    labels    = local.karakeep_chrome_labels
  }
  spec {
    selector = local.karakeep_chrome_labels
    port {
      port = local.karakeep_chrome_port
      target_port = local.karakeep_chrome_port
    }
  }
}

# Karakeep main app
resource "kubernetes_deployment_v1" "karakeep" {
  depends_on = [
    kubernetes_service_v1.karakeep_meilisearch,
    kubernetes_service_v1.karakeep_chrome,
    kubernetes_persistent_volume_claim_v1.karakeep_data,
  ]
  metadata {
    name      = "karakeep"
    namespace = local.karakeep_ns
    labels    = local.karakeep_labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = local.karakeep_labels }
    template {
      metadata { labels = local.karakeep_labels }
      spec {
        enable_service_links = false
        container {
          name  = "karakeep"
          image = local.karakeep_image

          env {
            name = "NEXTAUTH_SECRET"
            value = random_password.karakeep_nextauth_secret.result
          }
          env {
            name = "NEXTAUTH_URL"
            value = "https://${local.karakeep_host}"
          }
          env {
            name = "MEILI_ADDR"
            value = "http://karakeep-meilisearch.${local.karakeep_ns}.svc.cluster.local:${local.karakeep_meili_port}"
          }
          env {
            name = "MEILI_MASTER_KEY"
            value = random_password.karakeep_meili_master_key.result
          }
          env {
            name = "BROWSER_WEB_URL"
            value = "http://karakeep-chrome.${local.karakeep_ns}.svc.cluster.local:${local.karakeep_chrome_port}"
          }
          env {
            name = "OPENAI_API_KEY"
            value = var.secrets["litellm.virtual_keys.karakeep"]
          }
          env {
            name = "OPENAI_BASE_URL"
            value = "https://litellm.home.shdr.ch/v1"
          }
          env {
            name = "INFERENCE_TEXT_MODEL"
            value = "claude-sonnet-4-20250514"
          }
          env {
            name = "INFERENCE_IMAGE_MODEL"
            value = "o4-mini"
          }
          env {
            name = "EMBEDDING_TEXT_MODEL"
            value = "gemini-embedding-exp-03-07"
          }
          env {
            name = "INFERENCE_CONTEXT_LENGTH"
            value = "32000"
          }
          env {
            name = "INFERENCE_ENABLE_AUTO_SUMMARIZATION"
            value = "true"
          }
          env {
            name = "DATA_DIR"
            value = "/data"
          }

          port {
            container_port = local.karakeep_port
            name = "http"
          }

          volume_mount {
            name = "data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.karakeep_port
            }
            initial_delay_seconds = 20
            period_seconds        = 15
          }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.karakeep_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "karakeep" {
  metadata {
    name      = "karakeep"
    namespace = local.karakeep_ns
    labels    = local.karakeep_labels
  }
  spec {
    selector = local.karakeep_labels
    port {
      port = local.karakeep_port
      target_port = local.karakeep_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "karakeep_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.karakeep]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "karakeep", namespace = local.karakeep_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.karakeep_gateway_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "karakeep", port = local.karakeep_port }]
      }]
    }
  }
}
