# =============================================================================
# Antigravity Bridge — OpenAI-compatible Google Antigravity subscription API
# =============================================================================
# Source: ssh://git@ssh.gitlab.home.shdr.ch:2222/so/antigravity-bridge.git
# Single-tenant bridge: OAuth tokens stay server-side; callers authenticate with
# an independent random bearer token. Tool execution remains client-owned.

locals {
  antigravity_image         = "registry.gitlab.home.shdr.ch/so/antigravity-bridge@sha256:1d586a0ac6e5d1235c07b104c56c9e682588bf8ea3944b17a9ac580c9f4b0171"
  antigravity_host          = "antigravity.home.shdr.ch"
  antigravity_port          = 8080
  antigravity_ns            = module.namespace["antigravity"].name
  antigravity_labels        = { app = "antigravity-bridge" }
  antigravity_registry_host = "registry.gitlab.home.shdr.ch"
  antigravity_registry_user = var.secrets["gitlab.root_email"]
  antigravity_registry_pass = var.secrets["gitlab.root_password"]
}

resource "random_password" "antigravity_api_key" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "antigravity_registry" {
  depends_on = [module.namespace["antigravity"]]

  metadata {
    name      = "antigravity-registry"
    namespace = local.antigravity_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.antigravity_registry_host) = {
          username = local.antigravity_registry_user
          password = local.antigravity_registry_pass
          auth     = base64encode("${local.antigravity_registry_user}:${local.antigravity_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "antigravity_env" {
  depends_on = [module.namespace["antigravity"]]

  metadata {
    name      = "antigravity-env"
    namespace = local.antigravity_ns
  }

  data = {
    ANTIGRAVITY_CREDENTIALS = var.secrets["antigravity.google_credentials"]
    BRIDGE_API_KEY          = random_password.antigravity_api_key.result
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "antigravity" {
  depends_on = [
    kubernetes_secret_v1.antigravity_env,
    kubernetes_secret_v1.antigravity_registry,
  ]

  wait_for_rollout = false

  metadata {
    name      = "antigravity-bridge"
    namespace = local.antigravity_ns
    labels    = local.antigravity_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.antigravity_labels
    }

    template {
      metadata {
        labels = local.antigravity_labels
        annotations = {
          "aether.shdr.ch/antigravity-image" = local.antigravity_image
          "aether.shdr.ch/env-sha"           = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.antigravity_env.data)))
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

        image_pull_secrets {
          name = kubernetes_secret_v1.antigravity_registry.metadata[0].name
        }

        container {
          name              = "antigravity-bridge"
          image             = local.antigravity_image
          image_pull_policy = "IfNotPresent"

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "PORT"
            value = tostring(local.antigravity_port)
          }
          env {
            name = "ANTIGRAVITY_CREDENTIALS"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.antigravity_env.metadata[0].name
                key  = "ANTIGRAVITY_CREDENTIALS"
              }
            }
          }
          env {
            name = "BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.antigravity_env.metadata[0].name
                key  = "BRIDGE_API_KEY"
              }
            }
          }

          port {
            container_port = local.antigravity_port
            name           = "http"
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.antigravity_port
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.antigravity_port
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
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

resource "kubernetes_service_v1" "antigravity" {
  depends_on = [kubernetes_deployment_v1.antigravity]

  metadata {
    name      = "antigravity-bridge"
    namespace = local.antigravity_ns
    labels    = local.antigravity_labels
  }

  spec {
    selector = local.antigravity_labels

    port {
      port        = local.antigravity_port
      target_port = local.antigravity_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "antigravity_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.antigravity]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "antigravity"
      namespace = local.antigravity_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.antigravity_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.antigravity.metadata[0].name
          port = local.antigravity_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "antigravity_egress" {
  depends_on = [helm_release.cilium, kubernetes_deployment_v1.antigravity]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "antigravity-egress"
      namespace = local.antigravity_ns
    }
    spec = {
      endpointSelector = { matchLabels = local.antigravity_labels }
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
          toFQDNs = [
            { matchName = "oauth2.googleapis.com" },
            { matchName = "daily-cloudcode-pa.googleapis.com" },
            { matchName = "daily-cloudcode-pa.sandbox.googleapis.com" },
            { matchName = "cloudcode-pa.googleapis.com" },
          ]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
