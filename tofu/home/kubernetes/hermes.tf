# =============================================================================
# Hermes Agent — Personal + Dev Assistants
# =============================================================================
# Two isolated Hermes gateway instances with separate state, memories, sessions,
# personalities, and model backends.
#
# Beryl: fully local inference through llama-swap; LiteLLM MCP for tools.
# Tungsten: public Kimi model through LiteLLM -> Ollama Cloud.

locals {
  hermes_namespace              = module.namespace["hermes"].name
  hermes_image                  = "nousresearch/hermes-agent:latest"
  hermes_port                   = 8642
  hermes_dashboard_port         = 9119
  hermes_litellm                = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
  hermes_local_llm              = "http://${kubernetes_service_v1.llama_swap.metadata[0].name}.${local.llama_swap_ns}.svc.cluster.local:${local.llama_swap_port}/v1"
  hermes_jellyfin_url           = "http://${kubernetes_service_v1.jellyfin.metadata[0].name}.${local.jellyfin_ns}.svc.cluster.local:${local.jellyfin_port}"
  hermes_firecrawl_url          = "http://${kubernetes_service_v1.firecrawl.metadata[0].name}.${local.firecrawl_ns}.svc.cluster.local:${local.firecrawl_api_port}"
  hermes_searxng_url            = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.searxng_ns}.svc.cluster.local:${local.searxng_port}"
  hermes_matrix_server          = "http://${kubernetes_service_v1.synapse.metadata[0].name}.${local.matrix_ns}.svc.cluster.local:${local.synapse_port}"
  hermes_homeassistant          = "https://ha.home.shdr.ch"
  hermes_matrix_owner           = "@${var.secrets["matrix.admin_user"]}:matrix.home.shdr.ch"
  hermes_beryl_matrix_home_room = "!pkLDsPitwNliMhAELi:matrix.home.shdr.ch"
  hermes_tungsten_skills_root   = "${path.module}/../../../hermes/tungsten/skills"
  # Mnemo SKILL.md lives in the mnemo repo (single source of truth) and is
  # vendored at apply time. Requires the mnemo checkout as a sibling of aether.
  hermes_beryl_skills_root            = "${path.module}/../../../../mnemo/skills"
  hermes_bootstrap_init_base          = "mkdir -p /data /data/sessions /data/memories /data/skills /data/cron /data/logs /data/.npm && cp /bootstrap/config.yaml /data/config.yaml && cp /bootstrap/SOUL.md /data/SOUL.md && cp /bootstrap/AGENTS.md /data/AGENTS.md && chown 10000:10000 /data/config.yaml /data/SOUL.md /data/AGENTS.md && chown -R 10000:10000 /data/.npm && chmod 640 /data/config.yaml && chmod 644 /data/SOUL.md /data/AGENTS.md && chmod 755 /data /data/sessions /data/memories /data/skills /data/cron /data/logs"
  hermes_bootstrap_init_gitlab_skills = "mkdir -p /data/skills/gitlab/gitlab && cp /skills-bootstrap/gitlab-SKILL.md /data/skills/gitlab/gitlab/SKILL.md && chown -R 10000:10000 /data/skills/gitlab && chmod 644 /data/skills/gitlab/gitlab/SKILL.md"
  hermes_bootstrap_init_mnemo_skills  = "mkdir -p /data/skills/mnemo/mnemo && cp /skills-bootstrap/mnemo-SKILL.md /data/skills/mnemo/mnemo/SKILL.md && chown -R 10000:10000 /data/skills/mnemo && chmod 644 /data/skills/mnemo/mnemo/SKILL.md"

  hermes_agents = {
    beryl = {
      host           = "beryl.home.shdr.ch"
      dashboard_host = "beryl-dashboard.home.shdr.ch"
      env = {
        OPENAI_BASE_URL        = local.hermes_local_llm
        FIRECRAWL_API_URL      = local.hermes_firecrawl_url
        JELLYFIN_URL           = local.hermes_jellyfin_url
        LITELLM_MCP_URL        = var.litellm_mcp_url
        MATRIX_HOMESERVER      = local.hermes_matrix_server
        MATRIX_USER_ID         = "@${var.secrets["matrix.beryl_bot_user"]}:matrix.home.shdr.ch"
        MATRIX_ALLOWED_USERS   = local.hermes_matrix_owner
        MATRIX_ALLOWED_ROOMS   = local.hermes_beryl_matrix_home_room
        MATRIX_HOME_ROOM       = local.hermes_beryl_matrix_home_room
        MATRIX_HOME_ROOM_NAME  = "Beryl Home"
        MATRIX_REQUIRE_MENTION = "true"
        MATRIX_AUTO_THREAD     = "true"
        HASS_URL               = local.hermes_homeassistant
        SEARXNG_URL            = local.hermes_searxng_url
      }
      secret_env_keys = ["API_SERVER_KEY", "FIRECRAWL_API_KEY", "LITELLM_MCP_API_KEY", "MATRIX_ACCESS_TOKEN", "JELLYFIN_API_KEY", "HASS_TOKEN"]
      config = yamlencode({
        model = {
          provider       = "custom"
          default        = "qwen3.6-27b"
          base_url       = local.hermes_local_llm
          context_length = 262144
        }
        terminal = {
          backend          = "local"
          cwd              = "/opt/data"
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
        web = {
          search_backend  = "searxng"
          extract_backend = "firecrawl"
        }
        platforms = {
          homeassistant = {
            enabled = true
            extra = {
              # Hermes drops HA events unless at least one watch filter is set.
              # Keep this narrow: Beryl should notice low-frequency house state,
              # not every light, motion, presence, or telemetry update.
              watch_domains = [
                "alarm_control_panel",
                "climate",
              ]
              watch_entities = [
                "binary_sensor.entrance_diffuser_cloud_connection",
                "binary_sensor.q_sensor_ac_mains_disconnected",
                "binary_sensor.q_sensor_ac_mains_re_connected",
                "binary_sensor.q_sensor_replace_battery_now",
                "binary_sensor.q_sensor_replace_battery_soon",
              ]
              cooldown_seconds = 300
            }
          }
        }
        mcp_servers = {
          litellm = {
            url = "$${LITELLM_MCP_URL}"
            headers = {
              "x-litellm-api-key" = "Bearer $${LITELLM_MCP_API_KEY}"
            }
            timeout         = 180
            connect_timeout = 60
          }
          mnemo = {
            url             = "https://mnemo.home.shdr.ch/mcp"
            timeout         = 60
            connect_timeout = 15
          }
        }
        auxiliary = {
          vision = {
            provider = "main"
          }
          web_extract = {
            provider = "main"
          }
          skills_hub = {
            provider = "main"
          }
          mcp = {
            provider = "main"
          }
          flush_memories = {
            provider = "main"
          }
        }
        compression = {
          enabled      = true
          threshold    = 0.50
          target_ratio = 0.20
        }
        agent = {
          max_turns            = 90
          tool_use_enforcement = true
        }
      })
    }

    tungsten = {
      host           = "tungsten.home.shdr.ch"
      dashboard_host = "tungsten-dashboard.home.shdr.ch"
      env = {
        OPENAI_BASE_URL        = local.hermes_litellm
        FIRECRAWL_API_URL      = local.hermes_firecrawl_url
        GITLAB_HOST            = "gitlab.home.shdr.ch"
        GITLAB_URL             = "https://gitlab.home.shdr.ch"
        GRAFANA_URL            = "https://grafana.home.shdr.ch"
        JELLYFIN_URL           = local.hermes_jellyfin_url
        QBITTORRENT_URL        = "http://${kubernetes_service_v1.qbittorrent.metadata[0].name}.${local.jellyfin_ns}.svc.cluster.local:${local.qbittorrent_port}"
        SABNZBD_URL            = "http://${kubernetes_service_v1.sabnzbd.metadata[0].name}.${local.jellyfin_ns}.svc.cluster.local:${local.sabnzbd_port}"
        SONARR_URL             = "http://${kubernetes_service_v1.sonarr.metadata[0].name}.${local.jellyfin_ns}.svc.cluster.local:${local.sonarr_port}"
        RADARR_URL             = "http://${kubernetes_service_v1.radarr.metadata[0].name}.${local.jellyfin_ns}.svc.cluster.local:${local.radarr_port}"
        LIDARR_URL             = "http://${kubernetes_service_v1.lidarr.metadata[0].name}.${local.jellyfin_ns}.svc.cluster.local:${local.lidarr_port}"
        PROWLARR_URL           = "http://${kubernetes_service_v1.prowlarr.metadata[0].name}.${local.jellyfin_ns}.svc.cluster.local:${local.prowlarr_port}"
        MATRIX_HOMESERVER      = local.hermes_matrix_server
        MATRIX_USER_ID         = "@${var.secrets["matrix.tungsten_bot_user"]}:matrix.home.shdr.ch"
        MATRIX_ALLOWED_USERS   = local.hermes_matrix_owner
        MATRIX_REQUIRE_MENTION = "true"
        MATRIX_AUTO_THREAD     = "true"
        SEARXNG_URL            = local.hermes_searxng_url
      }
      secret_env_keys = [
        "API_SERVER_KEY",
        "OPENAI_API_KEY",
        "FIRECRAWL_API_KEY",
        "MATRIX_ACCESS_TOKEN",
        "GITLAB_TOKEN",
        "GRAFANA_SA_TOKEN",
        "JELLYFIN_API_KEY",
        "QBITTORRENT_USERNAME",
        "QBITTORRENT_PASSWORD",
        "SABNZBD_API_KEY",
        "SONARR_API_KEY",
        "RADARR_API_KEY",
        "LIDARR_API_KEY",
        "PROWLARR_API_KEY",
      ]
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
          cwd              = "/opt/data"
          timeout          = 180
          persistent_shell = true
          env_passthrough = [
            "PATH",
            "HOME",
            "HERMES_HOME",
            "GITLAB_HOST",
            "GITLAB_URL",
            "GITLAB_TOKEN",
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
        web = {
          search_backend  = "searxng"
          extract_backend = "firecrawl"
        }
        mcp_servers = {
          arr = {
            command = "npx"
            args    = ["-y", "mcp-arr-server"]
            env = {
              SONARR_URL       = "$${SONARR_URL}"
              SONARR_API_KEY   = "$${SONARR_API_KEY}"
              RADARR_URL       = "$${RADARR_URL}"
              RADARR_API_KEY   = "$${RADARR_API_KEY}"
              LIDARR_URL       = "$${LIDARR_URL}"
              LIDARR_API_KEY   = "$${LIDARR_API_KEY}"
              PROWLARR_URL     = "$${PROWLARR_URL}"
              PROWLARR_API_KEY = "$${PROWLARR_API_KEY}"
            }
            timeout = 180
            sampling = {
              enabled = false
            }
          }
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

  depends_on = [module.namespace["hermes"]]

  metadata {
    name      = "hermes-${each.key}-env"
    namespace = local.hermes_namespace
  }

  data = merge(
    {
      API_SERVER_KEY      = random_password.hermes_api_server_key[each.key].result
      FIRECRAWL_API_KEY   = var.secrets["firecrawl.api_key"]
      MATRIX_ACCESS_TOKEN = var.secrets["matrix.${each.key}_bot_access_token"]
    },
    each.key == "tungsten" ? {
      OPENAI_API_KEY       = var.secrets["litellm.virtual_keys.hermes_tungsten"]
      GITLAB_TOKEN         = var.secrets["gitlab.tungsten_token"]
      GRAFANA_SA_TOKEN     = var.secrets["grafana_sa_token"]
      JELLYFIN_API_KEY     = var.secrets["jellyfin.tungsten_api_key"]
      QBITTORRENT_USERNAME = var.secrets["qbittorrent.username"]
      QBITTORRENT_PASSWORD = var.secrets["qbittorrent.password"]
      SABNZBD_API_KEY      = var.secrets["sabnzbd.api_key"]
      SONARR_API_KEY       = var.secrets["sonarr.api_key"]
      RADARR_API_KEY       = var.secrets["radarr.api_key"]
      LIDARR_API_KEY       = var.secrets["lidarr.api_key"]
      PROWLARR_API_KEY     = var.secrets["prowlarr.api_key"]
    } : {},
    each.key == "beryl" ? {
      JELLYFIN_API_KEY    = var.secrets["jellyfin.beryl_api_key"]
      HASS_TOKEN          = var.secrets["homeassistant.beryl_token"]
      LITELLM_MCP_API_KEY = var.secrets["litellm.virtual_keys.hermes_beryl"]
    } : {}
  )

  type = "Opaque"
}

resource "kubernetes_config_map_v1" "hermes_bootstrap" {
  for_each = local.hermes_agents

  depends_on = [module.namespace["hermes"]]

  metadata {
    name      = "hermes-${each.key}-bootstrap"
    namespace = local.hermes_namespace
  }

  data = {
    "config.yaml" = each.value.config
    "SOUL.md"     = file("${path.module}/../../../hermes/${each.key}/SOUL.md")
    "AGENTS.md"   = file("${path.module}/../../../hermes/${each.key}/AGENTS.md")
  }
}

resource "kubernetes_config_map_v1" "hermes_tungsten_skills" {
  depends_on = [module.namespace["hermes"]]

  metadata {
    name      = "hermes-tungsten-skills"
    namespace = local.hermes_namespace
  }

  data = {
    "gitlab-SKILL.md" = file("${local.hermes_tungsten_skills_root}/gitlab/SKILL.md")
  }
}

resource "kubernetes_config_map_v1" "hermes_beryl_skills" {
  depends_on = [module.namespace["hermes"]]

  metadata {
    name      = "hermes-beryl-skills"
    namespace = local.hermes_namespace
  }

  # The mnemo SKILL.md is vendored from the mnemo repo at apply time. This couples
  # aether's tofu to a sibling mnemo checkout existing wherever `tofu apply` runs.
  # The precondition turns a missing checkout into an actionable failure rather
  # than a cryptic file() error.
  data = {
    "mnemo-SKILL.md" = file("${local.hermes_beryl_skills_root}/mnemo/SKILL.md")
  }

  lifecycle {
    precondition {
      condition     = fileexists("${local.hermes_beryl_skills_root}/mnemo/SKILL.md")
      error_message = "mnemo SKILL.md not found at ${local.hermes_beryl_skills_root}/mnemo/SKILL.md — clone the mnemo repo as a sibling of aether (next to ~/projects/aether) before running tofu apply."
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "hermes_data" {
  for_each = local.hermes_agents

  depends_on = [module.namespace["hermes"], kubernetes_storage_class_v1.ceph_rbd]

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

  lifecycle {
    prevent_destroy = true
  }
}


resource "kubernetes_service_account_v1" "hermes" {
  for_each = local.hermes_agents

  depends_on = [module.namespace["hermes"]]

  metadata {
    name      = "hermes-${each.key}"
    namespace = local.hermes_namespace
  }

  automount_service_account_token = each.key == "tungsten"

  image_pull_secret {
    name = "dockerhub-creds"
  }
}

resource "kubernetes_cluster_role_v1" "hermes_tungsten_readonly" {
  metadata {
    name = "hermes-tungsten-readonly"
  }

  rule {
    api_groups = [""]
    resources = [
      "configmaps",
      "endpoints",
      "events",
      "namespaces",
      "nodes",
      "persistentvolumeclaims",
      "persistentvolumes",
      "pods",
      "pods/log",
      "services",
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources = [
      "daemonsets",
      "deployments",
      "replicasets",
      "statefulsets",
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs", "jobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources  = ["gateways", "httproutes", "referencegrants"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["nodes", "pods"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "hermes_tungsten_readonly" {
  metadata {
    name = "hermes-tungsten-readonly"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.hermes["tungsten"].metadata[0].name
    namespace = local.hermes_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.hermes_tungsten_readonly.metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "hermes" {
  for_each = local.hermes_agents

  depends_on = [
    kubernetes_config_map_v1.hermes_bootstrap,
    kubernetes_config_map_v1.hermes_tungsten_skills,
    kubernetes_persistent_volume_claim_v1.hermes_data,
    kubernetes_secret_v1.hermes_env,
    kubernetes_service_account_v1.hermes,
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
        annotations = merge(
          {
            "checksum/config"    = sha256(each.value.config)
            "checksum/env"       = sha256(jsonencode(nonsensitive(kubernetes_secret_v1.hermes_env[each.key].data)))
            "checksum/bootstrap" = sha256(jsonencode(kubernetes_config_map_v1.hermes_bootstrap[each.key].data))
          },
          each.key == "tungsten" ? {
            "checksum/skills" = sha256(jsonencode(kubernetes_config_map_v1.hermes_tungsten_skills.data))
            } : each.key == "beryl" ? {
            "checksum/skills" = sha256(jsonencode(kubernetes_config_map_v1.hermes_beryl_skills.data))
          } : {}
        )
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.hermes[each.key].metadata[0].name
        automount_service_account_token = each.key == "tungsten"

        init_container {
          name  = "bootstrap-config"
          image = "busybox:latest"
          command = [
            "sh",
            "-c",
            each.key == "tungsten" ? "${local.hermes_bootstrap_init_base} && ${local.hermes_bootstrap_init_gitlab_skills}" :
            each.key == "beryl" ? "${local.hermes_bootstrap_init_base} && ${local.hermes_bootstrap_init_mnemo_skills}" :
            local.hermes_bootstrap_init_base
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

          dynamic "volume_mount" {
            for_each = each.key == "tungsten" || each.key == "beryl" ? [1] : []
            content {
              name       = "skills-bootstrap"
              mount_path = "/skills-bootstrap"
              read_only  = true
            }
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
          name  = "dashboard"
          image = local.hermes_image
          args = [
            "hermes",
            "dashboard",
            "--host",
            "0.0.0.0",
            "--port",
            tostring(local.hermes_dashboard_port),
            "--no-open",
            "--insecure",
            "--tui",
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
            name  = "HERMES_DASHBOARD_PUBLIC_URL"
            value = "https://${each.value.dashboard_host}"
          }

          env {
            name  = "HERMES_DASHBOARD_OIDC_ISSUER"
            value = var.oidc_issuer_url
          }

          env {
            name  = "HERMES_DASHBOARD_OIDC_CLIENT_ID"
            value = "hermes-dashboard"
          }

          env {
            name  = "HERMES_DASHBOARD_OIDC_SCOPES"
            value = "openid profile email"
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
            failure_threshold = 90
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

        dynamic "volume" {
          for_each = each.key == "tungsten" || each.key == "beryl" ? [1] : []
          content {
            name = "skills-bootstrap"
            config_map {
              name = each.key == "tungsten" ? kubernetes_config_map_v1.hermes_tungsten_skills.metadata[0].name : kubernetes_config_map_v1.hermes_beryl_skills.metadata[0].name
            }
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
