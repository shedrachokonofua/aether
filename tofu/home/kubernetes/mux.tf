# =============================================================================
# Mux — Standalone Agent Workspace Server
# =============================================================================
# Browser-accessible Mux server in a Kata pod. Workspaces and npm cache live on
# Ceph RBD so restarts do not lose local state.

resource "random_password" "mux_server_auth_token" {
  length  = 48
  special = false
}

locals {
  mux_image                 = "docker.io/library/node:22-bookworm"
  mux_version               = "0.24.0"
  mux_host                  = "mux.home.shdr.ch"
  mux_ns                    = kubernetes_namespace_v1.infra.metadata[0].name
  mux_labels                = { app = "mux" }
  mux_port                  = 3000
  mux_port_router_port      = 8080
  mux_port_host             = "*.mux.home.shdr.ch"
  mux_litellm_base_url      = "http://litellm.${kubernetes_namespace_v1.infra.metadata[0].name}.svc.cluster.local:${local.litellm_port}/v1"
  mux_default_model         = "litellm:xiaomi/mimo-v2.5-pro"
  mux_port_router_caddyfile = <<-EOT
    :${local.mux_port_router_port} {
      @muxPort header_regexp muxport Host ^(?P<port>[0-9]{2,5})\.mux\.home\.shdr\.ch$
      handle @muxPort {
        reverse_proxy 127.0.0.1:{re.muxport.port}
      }

      respond 404
    }
  EOT
  mux_litellm_models = [
    "xiaomi/mimo-v2.5-pro",
    "aether/qwen3.6-35b-a3b:code",
    "aether/qwen3.6-35b-a3b:think",
    "aether/qwen3.6-27b:code",
    "aether/qwen3.6-27b:think",
    "aether/qwen3.5-9b:think",
    "ollama-cloud/kimi-k2.6",
    "ollama-cloud/glm-5.1",
    "openai/gpt-5.5",
    "openai/gpt-5.4",
    "openai/gpt-5.4-mini",
    "anthropic/claude-opus-4.8",
    "anthropic/claude-sonnet-4.6",
    "openrouter/grok-4",
    "openrouter/gemini-3.1-pro-preview",
  ]
}

resource "kubernetes_manifest" "mux_kata_runtime_class" {
  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name = "kata"
    }
    handler = "kata"
    scheduling = {
      nodeSelector = {
        "kubernetes.io/arch" = "amd64"
      }
    }
  }
}

resource "kubernetes_secret_v1" "mux_env" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "mux-env"
    namespace = local.mux_ns
  }

  data = {
    MUX_SERVER_AUTH_TOKEN = random_password.mux_server_auth_token.result
    "litellm-api-key"     = var.secrets["litellm.virtual_keys.mux"]
  }

  type = "Opaque"
}

resource "kubernetes_config_map_v1" "mux_config" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "mux-config"
    namespace = local.mux_ns
  }

  data = {
    "config.json" = jsonencode({
      defaultModel = local.mux_default_model
    })

    "providers.jsonc" = jsonencode({
      litellm = {
        providerType = "openai-compatible"
        displayName  = "Aether LiteLLM"
        baseUrl      = local.mux_litellm_base_url
        apiKeyFile   = "/etc/mux/secrets/litellm-api-key"
        models       = local.mux_litellm_models
      }
    })
  }
}

resource "kubernetes_config_map_v1" "mux_port_router" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "mux-port-router"
    namespace = local.mux_ns
  }

  data = {
    "Caddyfile" = local.mux_port_router_caddyfile
  }
}

resource "kubernetes_persistent_volume_claim_v1" "mux_data" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "mux-data"
    namespace = local.mux_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = {
        storage = "200Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "mux" {
  depends_on = [
    kubernetes_manifest.mux_kata_runtime_class,
    kubernetes_config_map_v1.mux_config,
    kubernetes_config_map_v1.mux_port_router,
    kubernetes_secret_v1.mux_env,
    kubernetes_persistent_volume_claim_v1.mux_data,
  ]

  metadata {
    name      = "mux"
    namespace = local.mux_ns
    labels    = local.mux_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.mux_labels
    }

    template {
      metadata {
        labels = local.mux_labels
        annotations = {
          "aether.shdr.ch/config-sha"             = sha256(jsonencode(kubernetes_config_map_v1.mux_config.data))
          "aether.shdr.ch/port-router-config-sha" = sha256(local.mux_port_router_caddyfile)
        }
      }

      spec {
        runtime_class_name              = "kata"
        node_selector                   = { "kubernetes.io/arch" = "amd64" }
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "mux"
          image = local.mux_image

          command = ["/bin/bash", "-lc"]
          args = [<<-EOT
            set -euo pipefail
            export HOME=/data/home
            export PATH=/data/tools/bin:$PATH
            export XDG_CACHE_HOME=/data/cache
            export npm_config_cache=/data/npm-cache
            export CODER_URL=https://${local.coder_host}
            export CODER_CONFIG_DIR=$HOME/.config/coderv2
            export CODER_USE_KEYRING=false
            export DEBIAN_FRONTEND=noninteractive
            mkdir -p "$HOME/.mux" "$HOME/.ssh" "$CODER_CONFIG_DIR" /data/workspace /data/npm-cache /data/tools /data/cache
            if ! command -v coder >/dev/null 2>&1 || ! coder version 2>/dev/null | grep -q "v${local.coder_version}"; then
              curl -fsSL "https://${local.coder_host}/install.sh" | sh -s -- --prefix=/data/tools
            fi
            node <<'NODE'
            const fs = require("fs");
            const managedPath = "/etc/mux/config/config.json";
            const targetPath = process.env.HOME + "/.mux/config.json";
            const readJson = (path) => {
              try {
                return JSON.parse(fs.readFileSync(path, "utf8"));
              } catch {
                return {};
              }
            };
            const merged = { ...readJson(targetPath), ...readJson(managedPath) };
            fs.writeFileSync(targetPath, JSON.stringify(merged, null, 2) + "\n");
            NODE
            cp /etc/mux/config/providers.jsonc "$HOME/.mux/providers.jsonc"
            exec npx -y "mux@${local.mux_version}" server \
              --host 0.0.0.0 \
              --port ${local.mux_port} \
              --allow-http-origin \
              --add-project /data/workspace
          EOT
          ]

          port {
            container_port = local.mux_port
            name           = "http"
          }

          env {
            name = "MUX_SERVER_AUTH_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mux_env.metadata[0].name
                key  = "MUX_SERVER_AUTH_TOKEN"
              }
            }
          }

          env {
            name  = "HOME"
            value = "/data/home"
          }

          env {
            name  = "PATH"
            value = "/data/tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          }

          env {
            name  = "SHELL"
            value = "/bin/bash"
          }

          env {
            name  = "XDG_CACHE_HOME"
            value = "/data/cache"
          }

          env {
            name  = "npm_config_cache"
            value = "/data/npm-cache"
          }

          env {
            name  = "CODER_URL"
            value = "https://${local.coder_host}"
          }

          env {
            name  = "CODER_CONFIG_DIR"
            value = "/data/home/.config/coderv2"
          }

          env {
            name  = "CODER_USE_KEYRING"
            value = "false"
          }

          env {
            name  = "DEBIAN_FRONTEND"
            value = "noninteractive"
          }

          readiness_probe {
            tcp_socket {
              port = local.mux_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = local.mux_port
            }
            initial_delay_seconds = 60
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "2"
              memory = "8Gi"
            }
            limits = {
              cpu    = "8"
              memory = "8Gi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/mux/config"
            read_only  = true
          }

          volume_mount {
            name       = "secrets"
            mount_path = "/etc/mux/secrets"
            read_only  = true
          }
        }

        container {
          name    = "port-router"
          image   = "docker.io/library/caddy:2-alpine"
          command = ["caddy"]
          args    = ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

          port {
            container_port = local.mux_port_router_port
            name           = "http-ports"
          }

          readiness_probe {
            tcp_socket {
              port = local.mux_port_router_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = local.mux_port_router_port
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "port-router-config"
            mount_path = "/etc/caddy"
            read_only  = true
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.mux_data.metadata[0].name
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.mux_config.metadata[0].name
          }
        }

        volume {
          name = "secrets"
          secret {
            secret_name = kubernetes_secret_v1.mux_env.metadata[0].name
          }
        }

        volume {
          name = "port-router-config"
          config_map {
            name = kubernetes_config_map_v1.mux_port_router.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mux" {
  depends_on = [kubernetes_deployment_v1.mux]

  metadata {
    name      = "mux"
    namespace = local.mux_ns
    labels    = local.mux_labels
  }

  spec {
    selector = local.mux_labels

    port {
      name        = "http"
      port        = local.mux_port
      target_port = local.mux_port
    }
  }
}

resource "kubernetes_service_v1" "mux_port_router" {
  depends_on = [kubernetes_deployment_v1.mux]

  metadata {
    name      = "mux-port-router"
    namespace = local.mux_ns
    labels    = merge(local.mux_labels, { component = "port-router" })
  }

  spec {
    selector = local.mux_labels

    port {
      name        = "http-ports"
      port        = local.mux_port_router_port
      target_port = local.mux_port_router_port
    }
  }
}

resource "kubernetes_manifest" "mux_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.mux]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "mux"
      namespace = local.mux_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.mux_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.mux.metadata[0].name
          port = local.mux_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "mux_port_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.mux_port_router]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "mux-ports"
      namespace = local.mux_ns
    }
    spec = {
      parentRefs = [{
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "mux-ports"
      }]
      hostnames = [local.mux_port_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.mux_port_router.metadata[0].name
          port = local.mux_port_router_port
        }]
      }]
    }
  }
}
