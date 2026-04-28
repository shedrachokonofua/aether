# =============================================================================
# Perplexica — AI-powered Search
# =============================================================================
# Single container. Config.toml mounted from a Secret.
# SearXNG backend: searxng.home.shdr.ch (k8s)
#
# Data migration: tiny volumes (~32KB), can start fresh or copy:
#   perplexica-backend-dbstore-default-perplexica-1vcy9k → memos-data PVC

locals {
  perplexica_image        = "itzcrazykns1337/perplexica:latest"
  perplexica_host = "perplexica.home.shdr.ch"
  perplexica_port         = 3000
  perplexica_ns           = kubernetes_namespace_v1.personal.metadata[0].name
  perplexica_labels       = { app = "perplexica" }
}

resource "kubernetes_secret_v1" "perplexica_config" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "perplexica-config"
    namespace = local.perplexica_ns
  }

  data = {
    "config.toml" = <<-TOML
      [GENERAL]
      SIMILARITY_MEASURE = "cosine"

      [MODELS.CUSTOM_OPENAI]
      API_KEY = "${var.secrets["litellm.virtual_keys.perplexica"]}"
      API_URL = "https://litellm.home.shdr.ch/v1"
      MODEL_NAME = "openai/gpt-4o-mini"

      [MODELS.OPENAI]
      API_KEY = ""

      [MODELS.GROQ]
      API_KEY = ""

      [MODELS.ANTHROPIC]
      API_KEY = ""

      [MODELS.GEMINI]
      API_KEY = ""
    TOML
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "perplexica_data" {
  depends_on = [kubernetes_namespace_v1.personal, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "perplexica-data"
    namespace = local.perplexica_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "2Gi" } }
  }
}

resource "kubernetes_deployment_v1" "perplexica" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.perplexica_data,
    kubernetes_secret_v1.perplexica_config,
  ]

  metadata {
    name      = "perplexica"
    namespace = local.perplexica_ns
    labels    = local.perplexica_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = local.perplexica_labels
    }

    template {
      metadata { labels = local.perplexica_labels }

      spec {
        enable_service_links = false

        container {
          name  = "perplexica"
          image = local.perplexica_image

          env {
            name  = "SEARXNG_API_URL"
            value = "http://searxng.infra.svc.cluster.local:8080"
          }
          env {
            name  = "DATA_DIR"
            value = "/home/perplexica"
          }

          port {
            container_port = local.perplexica_port
            name           = "http"
          }

          volume_mount {
            name       = "data"
            mount_path = "/home/perplexica/data"
          }
          volume_mount {
            name       = "uploads"
            mount_path = "/home/perplexica/uploads"
          }
          volume_mount {
            name       = "config"
            mount_path = "/home/perplexica/config.toml"
            sub_path   = "config.toml"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.perplexica_port
            }
            initial_delay_seconds = 15
            period_seconds        = 15
          }
        }

        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.perplexica_data.metadata[0].name }
        }
        volume {
          name = "uploads"
          empty_dir {}
        }
        volume {
          name = "config"
          secret { secret_name = kubernetes_secret_v1.perplexica_config.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "perplexica" {
  metadata {
    name      = "perplexica"
    namespace = local.perplexica_ns
    labels    = local.perplexica_labels
  }
  spec {
    selector = local.perplexica_labels
    port {
      port = local.perplexica_port
      target_port = local.perplexica_port
      name = "http"
    }
  }
}

resource "kubernetes_manifest" "perplexica_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.perplexica]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "perplexica", namespace = local.perplexica_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.perplexica_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "perplexica", port = local.perplexica_port }]
      }]
    }
  }
}
