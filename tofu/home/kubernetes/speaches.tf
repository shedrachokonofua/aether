# =============================================================================
# Speaches — Speech-to-Text & Text-to-Speech
# =============================================================================
# OpenAI API-compatible STT (faster-whisper) and TTS (Kokoro) server.
# Dynamic model loading with TTL-based unloading, like llama-swap for speech.
#
# Used by OpenWebUI for voice input/output and meeting transcription.

locals {
  speaches_image  = "ghcr.io/speaches-ai/speaches:latest-cuda"
  speaches_host   = "speaches.apps.home.shdr.ch"
  speaches_port   = 8000
  speaches_ns     = kubernetes_namespace_v1.infra.metadata[0].name
  speaches_labels = { app = "speaches" }
}

# =============================================================================
# PVC — HuggingFace Model Cache (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "speaches_models" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "speaches-models"
    namespace = local.speaches_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "50Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "speaches" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.speaches_models,
  ]

  metadata {
    name      = "speaches"
    namespace = local.speaches_ns
    labels    = local.speaches_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.speaches_labels
    }

    template {
      metadata {
        labels = local.speaches_labels
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_node_selector

        security_context {
          fs_group = 1000
        }

        container {
          name  = "speaches"
          image = local.speaches_image

          port {
            container_port = local.speaches_port
            name           = "http"
          }

          env {
            name  = "WHISPER__INFERENCE_DEVICE"
            value = "cuda"
          }
          env {
            name  = "STT_MODEL_TTL"
            value = "300"
          }
          env {
            name  = "TTS_MODEL_TTL"
            value = "300"
          }
          env {
            name  = "LOOPBACK_HOST_URL"
            value = "http://localhost:${local.speaches_port}"
          }
          env {
            name  = "ENABLE_UI"
            value = "true"
          }

          volume_mount {
            name       = "models"
            mount_path = "/home/ubuntu/.cache/huggingface/hub"
          }

          resources {
            requests = {
              cpu              = "1"
              memory           = "2Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              memory           = "8Gi"
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.speaches_port
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            failure_threshold     = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.speaches_port
            }
            initial_delay_seconds = 60
            period_seconds        = 10
          }
        }

        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.speaches_models.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "speaches" {
  metadata {
    name      = "speaches"
    namespace = local.speaches_ns
    labels    = local.speaches_labels
  }

  spec {
    selector = local.speaches_labels

    port {
      port        = local.speaches_port
      target_port = local.speaches_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "speaches_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "speaches"
      namespace = local.speaches_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.speaches_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.speaches.metadata[0].name
          port = local.speaches_port
        }]
      }]
    }
  }
}
