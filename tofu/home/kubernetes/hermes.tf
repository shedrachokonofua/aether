# =============================================================================
# Hermes Agent — Personal + Dev Assistants
# =============================================================================
# Two isolated Hermes gateway instances with separate state, memories, sessions,
# personalities, and model backends.
#
# Beryl: fully local inference through llama-swap in-cluster.
# Tungsten: public Kimi model through LiteLLM -> Ollama Cloud.

locals {
  hermes_namespace      = kubernetes_namespace_v1.infra.metadata[0].name
  hermes_image          = "nousresearch/hermes-agent:latest"
  hermes_port           = 8642
  hermes_dashboard_port = 9119
  hermes_litellm        = "https://litellm.home.shdr.ch/v1"
  hermes_local_llm      = "http://${kubernetes_service_v1.llama_swap.metadata[0].name}.${local.hermes_namespace}.svc.cluster.local:${local.llama_swap_port}/v1"

  hermes_agents = {
    beryl = {
      host           = "hermes-beryl.apps.home.shdr.ch"
      dashboard_host = "hermes-beryl-dashboard.apps.home.shdr.ch"
      env = {
        OPENAI_BASE_URL = local.hermes_local_llm
      }
      secret_env_keys = ["API_SERVER_KEY"]
      config = yamlencode({
        model = {
          provider       = "custom"
          default        = "qwen3.6-27b"
          base_url       = local.hermes_local_llm
          context_length = 131072
        }
        terminal = {
          backend          = "local"
          cwd              = "/workspace"
          timeout          = 180
          persistent_shell = true
          env_passthrough = [
            "PATH",
            "HOME",
            "HERMES_HOME",
          ]
        }
        api_server = {
          enabled = true
          host    = "0.0.0.0"
          port    = local.hermes_port
        }
        memory = {
          memory_enabled       = true
          user_profile_enabled = true
        }
        compression = {
          enabled      = true
          threshold    = 0.50
          target_ratio = 0.20
        }
        agent = {
          max_turns = 60
        }
      })
    }

    tungsten = {
      host           = "hermes-tungsten.apps.home.shdr.ch"
      dashboard_host = "hermes-tungsten-dashboard.apps.home.shdr.ch"
      env = {
        OPENAI_BASE_URL = local.hermes_litellm
      }
      secret_env_keys = ["API_SERVER_KEY", "OPENAI_API_KEY"]
      config = yamlencode({
        model = {
          provider       = "custom"
          default        = "ollama-cloud/kimi-k2.6"
          base_url       = local.hermes_litellm
          api_key        = "$${OPENAI_API_KEY}"
          context_length = 256000
        }
        terminal = {
          backend          = "local"
          cwd              = "/workspace"
          timeout          = 180
          persistent_shell = true
          env_passthrough = [
            "PATH",
            "HOME",
            "HERMES_HOME",
          ]
        }
        api_server = {
          enabled = true
          host    = "0.0.0.0"
          port    = local.hermes_port
        }
        memory = {
          memory_enabled       = true
          user_profile_enabled = true
        }
        compression = {
          enabled      = true
          threshold    = 0.50
          target_ratio = 0.20
        }
        agent = {
          max_turns = 90
        }
      })
    }
  }
}

resource "random_password" "hermes_api_server_key" {
  for_each = local.hermes_agents

  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "hermes_env" {
  for_each = local.hermes_agents

  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "hermes-${each.key}-env"
    namespace = local.hermes_namespace
  }

  data = merge(
    {
      API_SERVER_KEY = random_password.hermes_api_server_key[each.key].result
    },
    each.key == "tungsten" ? {
      OPENAI_API_KEY = var.secrets["litellm.virtual_keys.hermes_tungsten"]
    } : {}
  )

  type = "Opaque"
}

resource "kubernetes_config_map_v1" "hermes_bootstrap" {
  for_each = local.hermes_agents

  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "hermes-${each.key}-bootstrap"
    namespace = local.hermes_namespace
  }

  data = {
    "config.yaml" = each.value.config
    "SOUL.md"     = file("${path.module}/../../../hermes/${each.key}/SOUL.md")
  }
}

resource "kubernetes_persistent_volume_claim_v1" "hermes_data" {
  for_each = local.hermes_agents

  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "hermes-${each.key}-data"
    namespace = local.hermes_namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "hermes" {
  for_each = local.hermes_agents

  depends_on = [
    kubernetes_config_map_v1.hermes_bootstrap,
    kubernetes_persistent_volume_claim_v1.hermes_data,
    kubernetes_secret_v1.hermes_env,
    kubernetes_service_v1.llama_swap,
  ]

  metadata {
    name      = "hermes-${each.key}"
    namespace = local.hermes_namespace
    labels = {
      app = "hermes-${each.key}"
    }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "hermes-${each.key}"
      }
    }

    template {
      metadata {
        labels = {
          app = "hermes-${each.key}"
        }
      }

      spec {
        init_container {
          name  = "bootstrap-config"
          image = "busybox:latest"
          command = [
            "sh",
            "-c",
            "mkdir -p /data /data/sessions /data/memories /data/skills /data/cron /data/logs && cp /bootstrap/config.yaml /data/config.yaml && cp /bootstrap/SOUL.md /data/SOUL.md && chown 10000:10000 /data/config.yaml /data/SOUL.md && chmod 640 /data/config.yaml && chmod 644 /data/SOUL.md && chmod 755 /data /data/sessions /data/memories /data/skills /data/cron /data/logs"
          ]

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "bootstrap"
            mount_path = "/bootstrap"
            read_only  = true
          }
        }

        container {
          name  = "hermes"
          image = local.hermes_image
          args  = ["hermes", "gateway", "run"]

          port {
            container_port = local.hermes_port
            name           = "http"
          }

          env {
            name  = "HERMES_HOME"
            value = "/opt/data"
          }

          env {
            name  = "HOME"
            value = "/opt/data"
          }

          env {
            name  = "GATEWAY_ALLOW_ALL_USERS"
            value = "true"
          }

          env {
            name  = "API_SERVER_ENABLED"
            value = "true"
          }

          env {
            name  = "API_SERVER_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "API_SERVER_PORT"
            value = tostring(local.hermes_port)
          }

          dynamic "env" {
            for_each = each.value.env
            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = each.value.secret_env_keys
            content {
              name = env.value
              value_from {
                secret_key_ref {
                  name = kubernetes_secret_v1.hermes_env[each.key].metadata[0].name
                  key  = env.value
                }
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/data"
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2"
              memory = "4Gi"
            }
          }

          startup_probe {
            http_get {
              path = "/health"
              port = local.hermes_port
            }
            period_seconds    = 10
            failure_threshold = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.hermes_port
            }
            period_seconds = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.hermes_port
            }
            period_seconds    = 30
            failure_threshold = 5
          }
        }

        container {
          name    = "dashboard"
          image   = local.hermes_image
          command = ["/bin/bash", "-lc"]
          args = [
            <<-EOT
            set -euo pipefail
            python3 - <<'PY'
            from pathlib import Path

            path = Path("/opt/hermes/hermes_cli/web_server.py")
            source = path.read_text()
            source = source.replace(
                "client_host and client_host not in _LOOPBACK_HOSTS",
                "False and client_host and client_host not in _LOOPBACK_HOSTS",
            )
            path.write_text(source)
            PY
            cd /opt/hermes/ui-tui
            npm install --silent --no-fund --no-audit --progress=false
            npm run build
            mkdir -p /opt/hermes/ui-tui/node_modules/@hermes/ink/dist
            cp /opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js /opt/hermes/ui-tui/node_modules/@hermes/ink/dist/ink-bundle.js
            chown -R hermes:hermes /opt/hermes/ui-tui
            exec /opt/hermes/docker/entrypoint.sh hermes dashboard --host 0.0.0.0 --port ${local.hermes_dashboard_port} --no-open --insecure --tui
            EOT
          ]

          port {
            container_port = local.hermes_dashboard_port
            name           = "dashboard"
          }

          env {
            name  = "HERMES_HOME"
            value = "/opt/data"
          }

          env {
            name  = "HOME"
            value = "/opt/data"
          }

          env {
            name  = "HERMES_DASHBOARD_TUI"
            value = "1"
          }

          env {
            name  = "GATEWAY_HEALTH_URL"
            value = "http://127.0.0.1:${local.hermes_port}"
          }

          env {
            name  = "API_SERVER_ENABLED"
            value = "true"
          }

          env {
            name  = "API_SERVER_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "API_SERVER_PORT"
            value = tostring(local.hermes_port)
          }

          dynamic "env" {
            for_each = each.value.env
            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = each.value.secret_env_keys
            content {
              name = env.value
              value_from {
                secret_key_ref {
                  name = kubernetes_secret_v1.hermes_env[each.key].metadata[0].name
                  key  = env.value
                }
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/data"
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1"
              memory = "2Gi"
            }
          }

          startup_probe {
            http_get {
              path = "/"
              port = local.hermes_dashboard_port
            }
            period_seconds    = 10
            failure_threshold = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.hermes_dashboard_port
            }
            period_seconds = 10
          }

          liveness_probe {
            http_get {
              path = "/"
              port = local.hermes_dashboard_port
            }
            period_seconds    = 30
            failure_threshold = 5
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.hermes_data[each.key].metadata[0].name
          }
        }

        volume {
          name = "bootstrap"
          config_map {
            name = kubernetes_config_map_v1.hermes_bootstrap[each.key].metadata[0].name
          }
        }

        volume {
          name = "workspace"
          empty_dir {}
        }

        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Gi"
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "hermes" {
  for_each = local.hermes_agents

  depends_on = [kubernetes_deployment_v1.hermes]

  metadata {
    name      = "hermes-${each.key}"
    namespace = local.hermes_namespace
    labels = {
      app = "hermes-${each.key}"
    }
  }

  spec {
    selector = {
      app = "hermes-${each.key}"
    }

    port {
      port        = local.hermes_port
      target_port = local.hermes_port
      protocol    = "TCP"
      name        = "http"
    }

    port {
      port        = local.hermes_dashboard_port
      target_port = local.hermes_dashboard_port
      protocol    = "TCP"
      name        = "dashboard"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_manifest" "hermes_dashboard_route" {
  for_each = local.hermes_agents

  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.hermes]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "hermes-${each.key}-dashboard"
      namespace = local.hermes_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [each.value.dashboard_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.hermes[each.key].metadata[0].name
          port = local.hermes_dashboard_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "hermes_route" {
  for_each = local.hermes_agents

  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.hermes]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "hermes-${each.key}"
      namespace = local.hermes_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [each.value.host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.hermes[each.key].metadata[0].name
          port = local.hermes_port
        }]
      }]
    }
  }
}
