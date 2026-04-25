# =============================================================================
# llama-swap — LLM Model Serving
# =============================================================================
# Manages llama-server processes with on-demand model loading/unloading.
# Replaces Ollama + vLLM on the GPU Workstation.
#
# Architecture: llama-swap (Go proxy) spawns llama-server child processes
# per model request, with TTL-based unloading to free VRAM.

locals {
  llama_swap_image   = "ghcr.io/mostlygeek/llama-swap:v202-cuda-b8808"
  llama_swap_host    = "llama-swap.apps.home.shdr.ch"
  llama_swap_port    = 8080
  llama_swap_ns      = kubernetes_namespace_v1.infra.metadata[0].name
  llama_swap_labels  = { app = "llama-swap" }
}

# =============================================================================
# PVC — Model Cache (Ceph RBD)
# =============================================================================
# Stores downloaded GGUFs. First model request triggers a HuggingFace download;
# subsequent starts load from this cache.

resource "kubernetes_persistent_volume_claim_v1" "llama_swap_models" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "llama-swap-models"
    namespace = local.llama_swap_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "200Gi" }
    }
  }
}

# =============================================================================
# ConfigMap — llama-swap config
# =============================================================================

resource "kubernetes_config_map_v1" "llama_swap_config" {
  metadata {
    name      = "llama-swap-config"
    namespace = local.llama_swap_ns
  }

  data = {
    "config.yaml" = <<-YAML
      healthCheckTimeout: 900
      logLevel: info
      logToStdout: both
      globalTTL: 300

      models:
        "qwen3.6-27b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/Qwen3.6-27B-GGUF:Q8_0
            -ngl 99
            --no-mmap
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 131072
          ttl: 900
          filters:
            setParamsByID:
              "qwen3.6-27b":
                chat_template_kwargs:
                  enable_thinking: false
              "qwen3.6-27b:code":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 0.6
                top_p: 0.95
                top_k: 20
              "qwen3.6-27b:think":
                chat_template_kwargs:
                  enable_thinking: true

        "qwen3.6-35b-a3b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/Qwen3.6-35B-A3B-GGUF:Q8_0
            -ngl 99
            --no-mmap
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 131072
          ttl: 900
          filters:
            setParamsByID:
              "qwen3.6-35b-a3b":
                chat_template_kwargs:
                  enable_thinking: false
              "qwen3.6-35b-a3b:code":
                chat_template_kwargs:
                  enable_thinking: true
                temperature: 0.6
                top_p: 0.95
                top_k: 20
              "qwen3.6-35b-a3b:think":
                chat_template_kwargs:
                  enable_thinking: true

        "bge-reranker-v2-m3":
          cmd: >
            llama-server
            --port $${PORT}
            -hf pyarn/bge-reranker-v2-m3-Q8_0-GGUF
            -ngl 99
            --reranking
          ttl: 120

        "gemma-4-31b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf unsloth/gemma-4-31B-it-GGUF:Q8_0
            -ngl 99
            --no-mmap
            --cache-type-k q8_0
            --cache-type-v q8_0
            --ctx-size 131072
          ttl: 900

        "qwen3-embedding-4b":
          cmd: >
            llama-server
            --port $${PORT}
            -hf Qwen/Qwen3-Embedding-4B-GGUF:Q8_0
            -ngl 99
            --embedding
            --pooling last
          ttl: 120

      matrix:
        vars:
          q3627: "qwen3.6-27b"
          q36: "qwen3.6-35b-a3b"
          g31: "gemma-4-31b"
          emb: "qwen3-embedding-4b"
          rr: "bge-reranker-v2-m3"
        sets:
          full: "q3627 & q36 & g31 & emb & rr"
    YAML
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "llama_swap" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.llama_swap_models,
  ]

  metadata {
    name      = "llama-swap"
    namespace = local.llama_swap_ns
    labels    = local.llama_swap_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.llama_swap_labels
    }

    template {
      metadata {
        labels = local.llama_swap_labels
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_node_selector

        init_container {
          name  = "fix-permissions"
          image = "busybox:latest"
          command = ["sh", "-c", "chmod -R 777 /models"]

          volume_mount {
            name       = "models"
            mount_path = "/models"
          }
        }

        container {
          name  = "llama-swap"
          image = local.llama_swap_image
          args  = ["-config", "/config/config.yaml"]

          port {
            container_port = local.llama_swap_port
            name           = "http"
          }

          env {
            name  = "LLAMA_CACHE"
            value = "/models"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }

          volume_mount {
            name       = "models"
            mount_path = "/models"
          }

          resources {
            requests = {
              cpu              = "2"
              memory           = "4Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              memory           = "32Gi"
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.llama_swap_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.llama_swap_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.llama_swap_config.metadata[0].name
          }
        }

        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.llama_swap_models.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "llama_swap" {
  metadata {
    name      = "llama-swap"
    namespace = local.llama_swap_ns
    labels    = local.llama_swap_labels
  }

  spec {
    selector = local.llama_swap_labels

    port {
      port        = local.llama_swap_port
      target_port = local.llama_swap_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "llama_swap_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "llama-swap"
      namespace = local.llama_swap_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.llama_swap_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.llama_swap.metadata[0].name
          port = local.llama_swap_port
        }]
      }]
    }
  }
}
