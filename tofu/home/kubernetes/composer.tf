# =============================================================================
# Composer API — thin OpenAI-compatible Cursor Grok bridge through OMP
# =============================================================================
# Source: ssh://git@ssh.gitlab.home.shdr.ch:2222/so/aether/composer-api.git
# Cursor credentials stay server-side. LiteLLM authenticates with a separate
# random bearer. Client-provided tools execute on the client and resume the
# bridge's in-memory Cursor turn.
#
# Endpoint: https://composer.home.shdr.ch/v1  (chat/completions, models)

locals {
  composer_image         = "registry.gitlab.home.shdr.ch/so/aether/composer-api@sha256:40b85281e04a5baa84e53487af2f2c317207c12d075ced27024ddfc6c3e2a8b4"
  composer_host          = "composer.home.shdr.ch"
  composer_port          = 8080
  composer_ns            = module.namespace["composer"].name
  composer_labels        = { app = "composer" }
  composer_registry_host = "registry.gitlab.home.shdr.ch"
  composer_registry_user = var.secrets["gitlab.root_email"]
  composer_registry_pass = var.secrets["gitlab.root_password"]
}

resource "random_password" "composer_bridge_api_key" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "composer_registry" {
  depends_on = [module.namespace["composer"]]

  metadata {
    name      = "composer-registry"
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
    CURSOR_API_KEY        = var.secrets["composer.cursor_api_key"]
    CURSOR_BRIDGE_API_KEY = random_password.composer_bridge_api_key.result
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "composer" {
  depends_on = [
    kubernetes_secret_v1.composer_env,
    kubernetes_secret_v1.composer_registry,
  ]

  wait_for_rollout = false

  metadata {
    name      = "composer"
    namespace = local.composer_ns
    labels    = local.composer_labels
  }

  spec {
    replicas = 1

    strategy { type = "Recreate" }

    selector { match_labels = local.composer_labels }

    template {
      metadata {
        labels = local.composer_labels
        annotations = {
          "aether.shdr.ch/composer-image" = local.composer_image
          "aether.shdr.ch/env-sha"        = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.composer_env.data)))
        }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false
        node_selector                   = { "kubernetes.io/arch" = "amd64" }

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }

        image_pull_secrets { name = kubernetes_secret_v1.composer_registry.metadata[0].name }

        container {
          name              = "composer-bridge"
          image             = local.composer_image
          image_pull_policy = "IfNotPresent"

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "PORT"
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
          env {
            name = "CURSOR_BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.composer_env.metadata[0].name
                key  = "CURSOR_BRIDGE_API_KEY"
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
            initial_delay_seconds = 3
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }

          liveness_probe {
            tcp_socket { port = local.composer_port }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
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

  field_manager { force_conflicts = true }

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

resource "kubernetes_manifest" "composer_egress" {
  depends_on = [helm_release.cilium, kubernetes_deployment_v1.composer]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "composer-egress"
      namespace = local.composer_ns
    }
    spec = {
      endpointSelector = { matchLabels = local.composer_labels }
      enableDefaultDeny = {
        egress  = true
        ingress = false
      }
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "k8s-app"                     = "kube-dns"
              "io.kubernetes.pod.namespace" = "kube-system"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
            rules = { dns = [{ matchPattern = "*" }] }
          }]
        },
        {
          toFQDNs = [{ matchName = "api2.cursor.sh" }]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
