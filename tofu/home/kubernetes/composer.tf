# =============================================================================
# Composer API — self-hosted OpenAI-compatible endpoint for Cursor Composer
# =============================================================================
# Lab-built image (so/aether/composer-api) runs bridge + OpenAI server via
# start.sh in one container. Callers send their Cursor API key as the Bearer
# token (Authorization: Bearer crsr_...). CURSOR_API_KEY is also set as a
# server-side fallback for probes and litellm.
#
# Endpoint: https://composer.home.shdr.ch/v1  (chat/completions, responses, models)

locals {
  composer_image         = "registry.gitlab.home.shdr.ch/so/aether/composer-api:latest"
  composer_host          = "composer.home.shdr.ch"
  composer_port          = 8080
  composer_ns            = module.namespace["composer"].name
  composer_labels        = { app = "composer" }
  composer_registry_host = "registry.gitlab.home.shdr.ch"
  composer_registry_user = var.secrets["gitlab.root_email"]
  composer_registry_pass = var.secrets["gitlab.root_password"]
}

resource "kubernetes_secret_v1" "composer_gitlab_registry" {
  depends_on = [module.namespace["composer"]]

  metadata {
    name      = "composer-gitlab-registry"
    namespace = local.composer_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.composer_registry_host) = {
          username = local.composer_registry_user
          password = local.composer_registry_pass
          auth     = base64encode("${local.composer_registry_user}:${local.composer_registry_pass}")
        }
      }
    })
  }
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
  depends_on = [
    kubernetes_secret_v1.composer_gitlab_registry,
    kubernetes_secret_v1.composer_env,
  ]

  wait_for_rollout = false

  metadata {
    name      = "composer"
    namespace = local.composer_ns
    labels    = local.composer_labels
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
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

        image_pull_secrets {
          name = kubernetes_secret_v1.composer_gitlab_registry.metadata[0].name
        }

        container {
          name              = "composer-api"
          image             = local.composer_image
          image_pull_policy = "Always"

          env {
            name  = "HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "PORT"
            value = tostring(local.composer_port)
          }
          env {
            name  = "NODE_OPTIONS"
            value = "--dns-result-order=ipv4first"
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
      # Keel force-updates rewrite these on a new :latest digest; tofu must not revert them.
      metadata[0].annotations["kubernetes.io/change-cause"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
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
