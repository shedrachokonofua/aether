# =============================================================================
# Claude Bridge — Anthropic Messages subscription API via pi-ai
# =============================================================================
# Source: ssh://git@ssh.gitlab.home.shdr.ch:2222/so/claude-bridge.git
# Single-tenant bridge: OAuth credentials remain in OpenBao; callers authenticate
# with an independent random bearer token. There is no API-key or PAYG fallback.
# In-cluster egress is limited to OpenBao, platform.claude.com (token refresh),
locals {
  claude_image         = "registry.gitlab.home.shdr.ch/so/claude-bridge@sha256:e755c604e0f69dc462a16e26198db0f9e4cdd32d4761fe5a1169b84aeff7d922"
  claude_host          = "claude.home.shdr.ch"
  claude_port          = 8080
  claude_ns            = module.namespace["claude"].name
  claude_labels        = { app = "claude-bridge" }
  claude_registry_host = "registry.gitlab.home.shdr.ch"
  claude_registry_user = var.secrets["gitlab.root_email"]
  claude_registry_pass = var.secrets["gitlab.root_password"]
}

resource "random_password" "claude_bridge_api_key" {
  length  = 48
  special = false
}

resource "kubernetes_service_account_v1" "claude_bridge" {
  metadata {
    name      = "claude-bridge"
    namespace = local.claude_ns
  }
}

resource "vault_policy" "claude_bridge" {
  name = "aether-k8s-claude-bridge"

  policy = <<-EOT
    path "${var.openbao_kv_mount_path}/data/aether/claude-bridge/credentials" {
      capabilities = ["create", "read", "update"]
    }

    path "${var.openbao_kv_mount_path}/metadata/aether/claude-bridge/credentials" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "claude_bridge" {
  backend   = vault_auth_backend.kubernetes_aether.path
  role_name = "aether-k8s-claude-bridge"

  bound_service_account_names      = [kubernetes_service_account_v1.claude_bridge.metadata[0].name]
  bound_service_account_namespaces = [local.claude_ns]
  audience                         = local.openbao_external_secrets_audience

  token_policies = [vault_policy.claude_bridge.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}

resource "kubernetes_secret_v1" "claude_registry" {
  depends_on = [module.namespace["claude"]]

  metadata {
    name      = "claude-registry"
    namespace = local.claude_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.claude_registry_host) = {
          username = local.claude_registry_user
          password = local.claude_registry_pass
          auth     = base64encode("${local.claude_registry_user}:${local.claude_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "claude_env" {
  depends_on = [module.namespace["claude"]]

  metadata {
    name      = "claude-env"
    namespace = local.claude_ns
  }

  data = {
    BRIDGE_API_KEY = random_password.claude_bridge_api_key.result
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "claude" {
  depends_on = [
    kubernetes_secret_v1.claude_env,
    kubernetes_secret_v1.claude_registry,
    vault_kubernetes_auth_backend_role.claude_bridge,
  ]

  wait_for_rollout = false

  metadata {
    name      = "claude-bridge"
    namespace = local.claude_ns
    labels    = local.claude_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.claude_labels
    }

    template {
      metadata {
        labels = local.claude_labels
        annotations = {
          "aether.shdr.ch/claude-image" = local.claude_image
          "aether.shdr.ch/env-sha"      = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.claude_env.data)))
        }
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.claude_bridge.metadata[0].name
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
          name = kubernetes_secret_v1.claude_registry.metadata[0].name
        }

        container {
          name              = "claude-bridge"
          image             = local.claude_image
          image_pull_policy = "IfNotPresent"

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "PORT"
            value = tostring(local.claude_port)
          }
          env {
            name = "BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.claude_env.metadata[0].name
                key  = "BRIDGE_API_KEY"
              }
            }
          }
          env {
            name  = "BAO_ADDR"
            value = "https://bao.home.shdr.ch"
          }
          env {
            name  = "BAO_AUTH_PATH"
            value = vault_auth_backend.kubernetes_aether.path
          }
          env {
            name  = "BAO_ROLE"
            value = vault_kubernetes_auth_backend_role.claude_bridge.role_name
          }
          env {
            name  = "BAO_KV_MOUNT"
            value = var.openbao_kv_mount_path
          }
          env {
            name  = "BAO_SECRET_PATH"
            value = "aether/claude-bridge/credentials"
          }
          env {
            name  = "BAO_JWT_PATH"
            value = "/var/run/secrets/openbao/token"
          }

          port {
            container_port = local.claude_port
            name           = "http"
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = local.claude_port
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.claude_port
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          volume_mount {
            name       = "openbao-token"
            mount_path = "/var/run/secrets/openbao"
            read_only  = true
          }
        }

        volume {
          name = "openbao-token"
          projected {
            sources {
              service_account_token {
                path               = "token"
                audience           = local.openbao_external_secrets_audience
                expiration_seconds = 600
              }
            }
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

resource "kubernetes_service_v1" "claude" {
  depends_on = [kubernetes_deployment_v1.claude]

  metadata {
    name      = "claude-bridge"
    namespace = local.claude_ns
    labels    = local.claude_labels
  }

  spec {
    selector = local.claude_labels

    port {
      port        = local.claude_port
      target_port = local.claude_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "claude_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.claude]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "claude"
      namespace = local.claude_ns
    }
    spec = {
      parentRefs = [{
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "http"
      }]
      hostnames = [local.claude_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.claude.metadata[0].name
          port = local.claude_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "claude_egress" {
  depends_on = [helm_release.cilium, kubernetes_deployment_v1.claude]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "claude-egress"
      namespace = local.claude_ns
    }
    spec = {
      endpointSelector = { matchLabels = local.claude_labels }
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
            { matchName = "api.anthropic.com" },
            { matchName = "bao.home.shdr.ch" },
            { matchName = "platform.claude.com" },
          ]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
