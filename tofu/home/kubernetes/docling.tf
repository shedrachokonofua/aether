# =============================================================================
# Docling — Document Parsing & OCR
# =============================================================================
# GPU-accelerated document conversion service (PDF, DOCX, images → structured
# text). Used by OpenWebUI for content extraction.

locals {
  docling_image  = "ghcr.io/docling-project/docling-serve-cu128:main"
  docling_host   = "docling.home.shdr.ch"
  docling_port   = 5001
  docling_ns     = kubernetes_namespace_v1.infra.metadata[0].name
  docling_labels = { app = "docling" }

  # Model cache lives on the talos-neo local-NVMe PV under docling/models/.
  # The image's baked cache (RapidOCR, EasyOCR, layout heron, table former,
  # picture classifier) is seeded into the PV by the init container, plus
  # Qwen/Qwen2.5-VL-3B-Instruct for the VLM pipeline (the chosen default).
  # Bench across preset {default, smoldocling, dolphin, granite_vision,
  # nanonets_ocr2, qwen, lightonocr} on a CamScanner scan: qwen was the only
  # one that captured handwritten margin notes AND printed text without
  # hallucinating; granite_vision and nanonets_ocr2 produced broken output.
  # The cache is mounted at a fresh path and exposed via DOCLING_SERVE_ARTIFACTS_PATH
  # so the image's original baked cache stays readable to the init container.
  docling_models_subpath = "docling/models"
  docling_models_path    = "/var/lib/docling-models"
  docling_baked_path     = "/opt/app-root/src/.cache/docling/models"
  docling_vlm_model_repo = "Qwen/Qwen2.5-VL-3B-Instruct"
  docling_vlm_model_dir  = "Qwen--Qwen2.5-VL-3B-Instruct"
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "docling" {
  depends_on = [helm_release.nvidia_device_plugin]

  metadata {
    name      = "docling"
    namespace = local.docling_ns
    labels    = local.docling_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.docling_labels
    }

    template {
      metadata {
        labels = local.docling_labels
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_node_selector

        # Seed the model PV from the image's baked cache (first run only) and
        # download the granite-docling-258M VLM weights if absent. Runs as root
        # so it can chown the freshly bound subPath to the docling user.
        init_container {
          name  = "init-models"
          image = local.docling_image

          security_context {
            run_as_user  = 0
            run_as_group = 0
          }

          command = ["bash", "-c"]
          args = [
            <<-EOT
            set -euo pipefail
            TARGET=${local.docling_models_path}
            BAKED=${local.docling_baked_path}

            chown 1001:0 "$TARGET"
            chmod 2775 "$TARGET"

            for d in EasyOcr RapidOcr \
                     docling-project--docling-layout-heron \
                     docling-project--docling-models \
                     docling-project--DocumentFigureClassifier-v2.5; do
              if [ ! -d "$TARGET/$d" ] && [ -d "$BAKED/$d" ]; then
                echo "Seeding $d from baked image cache"
                cp -a "$BAKED/$d" "$TARGET/"
              fi
            done

            if [ ! -d "$TARGET/${local.docling_vlm_model_dir}" ]; then
              echo "Downloading ${local.docling_vlm_model_repo}"
              docling-tools models download-hf-repo ${local.docling_vlm_model_repo} -o "$TARGET"
            else
              echo "${local.docling_vlm_model_dir} already present"
            fi

            chown -R 1001:0 "$TARGET"
            EOT
          ]

          volume_mount {
            name       = "models"
            mount_path = local.docling_models_path
            sub_path   = local.docling_models_subpath
          }
        }

        container {
          name  = "docling"
          image = local.docling_image

          port {
            container_port = local.docling_port
            name           = "http"
          }

          env {
            name  = "DOCLING_SERVE_ENABLE_UI"
            value = "true"
          }

          # Trust X-Forwarded-Proto from the gateway so Gradio emits https:// asset URLs.
          # Without this, uvicorn only trusts 127.0.0.1 and the UI loads http://…/theme.css,
          # which the browser blocks as mixed content.
          env {
            name  = "FORWARDED_ALLOW_IPS"
            value = "*"
          }

          # Use the persisted PV cache instead of the (immutable) baked image
          # path. Lets us add VLM weights at runtime and survive image upgrades.
          env {
            name  = "DOCLING_SERVE_ARTIFACTS_PATH"
            value = local.docling_models_path
          }

          # OpenWebUI hits the sync /v1/convert/file endpoint. VLM runs are
          # ~15-30s on this GPU but can stretch on larger PDFs; default 120s
          # is too tight, set to 30 minutes so big uploads still complete sync.
          env {
            name  = "DOCLING_SERVE_MAX_SYNC_WAIT"
            value = "1800"
          }

          resources {
            requests = {
              cpu              = "1"
              memory           = "2Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.docling_port
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.docling_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          volume_mount {
            name       = "models"
            mount_path = local.docling_models_path
            sub_path   = local.docling_models_subpath
          }
        }

        # Shared GPU model PV (talos-neo local NVMe). Each workload gets its
        # own subdir; docling lives under docling/models.
        volume {
          name = "models"
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

resource "kubernetes_service_v1" "docling" {
  metadata {
    name      = "docling"
    namespace = local.docling_ns
    labels    = local.docling_labels
  }

  spec {
    selector = local.docling_labels

    port {
      port        = local.docling_port
      target_port = local.docling_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "docling_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "docling"
      namespace = local.docling_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.docling_host]
      rules = [{
        # Tell uvicorn the original scheme — without this the Gradio UI emits
        # http://…/theme.css and http://…/gradio_api/* URLs that the browser
        # blocks as mixed content.
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.docling.metadata[0].name
          port = local.docling_port
        }]
      }]
    }
  }
}
