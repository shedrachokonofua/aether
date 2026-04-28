# =============================================================================
# ComfyUI — GPU Image Generation Workbench
# =============================================================================

locals {
  comfyui_image   = "docker.io/yanwk/comfyui-boot:cu129-slim"
  comfyui_host    = "comfyui.home.shdr.ch"
  comfyui_port    = 8188
  comfyui_ns      = kubernetes_namespace_v1.infra.metadata[0].name
  comfyui_subpath = "comfyui/root"
  comfyui_labels  = { app = "comfyui" }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "comfyui" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.gpu_model_storage,
  ]

  metadata {
    name      = "comfyui"
    namespace = local.comfyui_ns
    labels    = local.comfyui_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.comfyui_labels
    }

    template {
      metadata {
        labels = local.comfyui_labels
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_node_selector

        init_container {
          name  = "init-storage"
          image = "busybox:latest"
          # Idempotent: only ensures the sub-path exists and is world-writable.
          # Must NOT run `chmod -R` on the populated tree — that's ~99G of
          # restored state and a recursive chmod re-walks it on every restart.
          command = ["sh", "-c", "mkdir -p /gpu-storage/${local.comfyui_subpath} && chmod 777 /gpu-storage/${local.comfyui_subpath}"]

          volume_mount {
            name       = "storage"
            mount_path = "/gpu-storage"
          }
        }

        container {
          name  = "comfyui"
          image = local.comfyui_image

          # The cu129-slim image omits `comfy_kitchen`, which ComfyUI's fp8/fp4
          # ops path requires for FLUX fp8 checkpoints. Install it (and bump the
          # frontend package the image ships at 1.27 vs recommended 1.36+)
          # before handing off to the upstream entrypoint at /runner-scripts/.
          command = ["bash", "-c"]
          args = [
            "set -e; /usr/bin/python3 -m pip install --no-cache-dir --quiet comfy-kitchen 'comfyui-frontend-package>=1.36.14'; exec bash /runner-scripts/entrypoint.sh"
          ]

          port {
            container_port = local.comfyui_port
            name           = "http"
          }

          env {
            name  = "CLI_ARGS"
            value = "--use-pytorch-cross-attention --fast fp16_accumulation --normalvram --reserve-vram 1 --fp16-vae --cuda-malloc"
          }

          env {
            name  = "NVIDIA_VISIBLE_DEVICES"
            value = "all"
          }

          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "compute,utility"
          }

          volume_mount {
            name       = "storage"
            mount_path = "/root"
            sub_path   = local.comfyui_subpath
          }

          resources {
            requests = {
              cpu              = "2"
              memory           = "8Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              memory           = "32Gi"
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.comfyui_port
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.comfyui_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.gpu_model_storage.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "comfyui" {
  metadata {
    name      = "comfyui"
    namespace = local.comfyui_ns
    labels    = local.comfyui_labels
  }

  spec {
    selector = local.comfyui_labels

    port {
      port        = local.comfyui_port
      target_port = local.comfyui_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "comfyui_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.comfyui]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "comfyui"
      namespace = local.comfyui_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.comfyui_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.comfyui.metadata[0].name
          port = local.comfyui_port
        }]
      }]
    }
  }
}
