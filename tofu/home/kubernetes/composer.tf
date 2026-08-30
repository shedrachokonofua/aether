# =============================================================================
# Composer API — cursorpipe: OpenAI-compatible endpoint for Cursor models
# =============================================================================
# ghcr.io/abhi5h3k/cursorpipe (Cursor Python SDK bridge + FastAPI server).
# Replaced the lab-built so/aether/composer-api 2026-08-30: cursorpipe serves
# the full Cursor model catalog (grok-4.6 etc.), true SSE streaming, and
# /health reflects bridge state. Auth is server-side CURSOR_API_KEY only
# (CURSORPIPE_BEARER_TOKEN unset = no inbound auth; internal + gateway route).
# Image is digest-pinned; bump deliberately.
#
# Endpoint: https://composer.home.shdr.ch/v1  (chat/completions, models)

locals {
  composer_image  = "ghcr.io/abhi5h3k/cursorpipe:latest@sha256:6522390f3f74d8ac4e7a45b8b170952f891b34a693efc2caa70d602c905b55f7"
  composer_host   = "composer.home.shdr.ch"
  composer_port   = 8080
  composer_ns     = module.namespace["composer"].name
  composer_labels = { app = "composer" }
}


resource "kubernetes_secret_v1" "composer_env" {
  depends_on = [module.namespace["composer"]]

  metadata {
    name      = "composer-env"
    namespace = local.composer_ns
  }

  data = {
    CURSOR_API_KEY = var.secrets["composer.cursor_api_key"]
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "composer" {
  depends_on = [kubernetes_secret_v1.composer_env]

  wait_for_rollout = false

  metadata {
    name      = "composer"
    namespace = local.composer_ns
    labels    = local.composer_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.composer_labels
    }

    template {
      metadata {
        labels = local.composer_labels
        annotations = {
          "aether.shdr.ch/composer-image" = local.composer_image
        }
      }

      spec {
        enable_service_links = false

        # ghcr cursorpipe publishes amd64 only (no buildx in its workflow);
        # also keeps the pod clear of the kyverno ARM-pool bind guardrail.
        node_selector = { "kubernetes.io/arch" = "amd64" }

        container {
          name              = "cursorpipe"
          image             = local.composer_image
          image_pull_policy = "IfNotPresent"

          env {
            name  = "CURSORPIPE_PORT"
            value = tostring(local.composer_port)
          }
          env {
            name = "CURSOR_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.composer_env.metadata[0].name
                key  = "CURSOR_API_KEY"
              }
            }
          }

          port {
            container_port = local.composer_port
            name           = "http"
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.composer_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.composer_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "1Gi" }
          }
        }
      }
    }
  }


  lifecycle {
    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_service_v1" "composer" {
  depends_on = [kubernetes_deployment_v1.composer]

  metadata {
    name      = "composer"
    namespace = local.composer_ns
    labels    = local.composer_labels
  }

  spec {
    selector = local.composer_labels

    port {
      port        = local.composer_port
      target_port = local.composer_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "composer_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.composer]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "composer"
      namespace = local.composer_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.composer_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.composer.metadata[0].name
          port = local.composer_port
        }]
      }]
    }
  }
}
