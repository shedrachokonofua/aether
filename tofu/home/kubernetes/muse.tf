# =============================================================================
# Muse Bridge — OpenAI-compatible Muse Code subscription API
# =============================================================================
# Source: ssh://git@ssh.gitlab.home.shdr.ch:2222/so/muse-bridge.git
# Single-tenant bridge: OAuth credentials remain in OpenBao; callers authenticate
# with an independent random bearer token. There is no PAYG fallback.

locals {
  muse_image         = "registry.gitlab.home.shdr.ch/so/muse-bridge@sha256:20c4e2f81334092da94dc74fb4e2a03f3d85e98a9f40267d17fc1a7b8d0ae9b2"
  muse_host          = "muse.home.shdr.ch"
  muse_port          = 8080
  muse_ns            = module.namespace["muse"].name
  muse_labels        = { app = "muse-bridge" }
  muse_registry_host = "registry.gitlab.home.shdr.ch"
  muse_registry_user = var.secrets["gitlab.root_email"]
  muse_registry_pass = var.secrets["gitlab.root_password"]
}

resource "random_password" "muse_bridge_api_key" {
  length  = 48
  special = false
}

resource "kubernetes_service_account_v1" "muse_bridge" {
  metadata {
    name      = "muse-bridge"
    namespace = local.muse_ns
  }
}

resource "vault_policy" "muse_bridge" {
  name = "aether-k8s-muse-bridge"

  policy = <<-EOT
    path "${var.openbao_kv_mount_path}/data/aether/muse-bridge/credentials" {
      capabilities = ["create", "read", "update"]
    }

    path "${var.openbao_kv_mount_path}/metadata/aether/muse-bridge/credentials" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "muse_bridge" {
  backend   = vault_auth_backend.kubernetes_aether.path
  role_name = "aether-k8s-muse-bridge"

  bound_service_account_names      = [kubernetes_service_account_v1.muse_bridge.metadata[0].name]
  bound_service_account_namespaces = [local.muse_ns]
  audience                         = local.openbao_external_secrets_audience

  token_policies = [vault_policy.muse_bridge.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}

resource "kubernetes_secret_v1" "muse_registry" {
  depends_on = [module.namespace["muse"]]

  metadata {
    name      = "muse-registry"
    namespace = local.muse_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.muse_registry_host) = {
          username = local.muse_registry_user
          password = local.muse_registry_pass
          auth     = base64encode("${local.muse_registry_user}:${local.muse_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "muse_env" {
  depends_on = [module.namespace["muse"]]

  metadata {
    name      = "muse-env"
    namespace = local.muse_ns
  }

  data = {
    BRIDGE_API_KEY = random_password.muse_bridge_api_key.result
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "muse" {
  depends_on = [
    kubernetes_secret_v1.muse_env,
    kubernetes_secret_v1.muse_registry,
    vault_kubernetes_auth_backend_role.muse_bridge,
  ]

  wait_for_rollout = false

  metadata {
    name      = "muse-bridge"
    namespace = local.muse_ns
    labels    = local.muse_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.muse_labels
    }

    template {
      metadata {
        labels = local.muse_labels
        annotations = {
          "aether.shdr.ch/muse-image" = local.muse_image
          "aether.shdr.ch/env-sha"    = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.muse_env.data)))
        }
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.muse_bridge.metadata[0].name
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
          name = kubernetes_secret_v1.muse_registry.metadata[0].name
        }

        container {
          name              = "muse-bridge"
          image             = local.muse_image
          image_pull_policy = "IfNotPresent"

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "PORT"
            value = tostring(local.muse_port)
          }
          env {
            name = "BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.muse_env.metadata[0].name
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
            value = vault_kubernetes_auth_backend_role.muse_bridge.role_name
          }
          env {
            name  = "BAO_KV_MOUNT"
            value = var.openbao_kv_mount_path
          }
          env {
            name  = "BAO_SECRET_PATH"
            value = "aether/muse-bridge/credentials"
          }
          env {
            name  = "BAO_JWT_PATH"
            value = "/var/run/secrets/openbao/token"
          }

          port {
            container_port = local.muse_port
            name           = "http"
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = local.muse_port
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.muse_port
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

resource "kubernetes_service_v1" "muse" {
  depends_on = [kubernetes_deployment_v1.muse]

  metadata {
    name      = "muse-bridge"
    namespace = local.muse_ns
    labels    = local.muse_labels
  }

  spec {
    selector = local.muse_labels

    port {
      port        = local.muse_port
      target_port = local.muse_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "muse_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.muse]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "muse"
      namespace = local.muse_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.muse_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.muse.metadata[0].name
          port = local.muse_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "muse_egress" {
  depends_on = [helm_release.cilium, kubernetes_deployment_v1.muse]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "muse-egress"
      namespace = local.muse_ns
    }
    spec = {
      endpointSelector = { matchLabels = local.muse_labels }
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
            { matchName = "api.meta.ai" },
            { matchName = "auth.meta.com" },
            { matchName = "bao.home.shdr.ch" },
          ]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
