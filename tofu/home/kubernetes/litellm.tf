# Sourcegull MCP access token (litellm-mcp service account, kubernetes/sourcegull.tf).
data "vault_kv_secret_v2" "sourcegull_mcp" {
  mount = "kv"
  name  = "sourcegull/mcp"
}

# =============================================================================
# LiteLLM — LLM Gateway + MCP
# =============================================================================
# Migrated from the legacy Podman VM to Kubernetes.

locals {
  litellm_image          = "ghcr.io/berriai/litellm:v1.106.0-rc.1@sha256:de5b050c1e9bd7e6c0aebfa126c5df71de071962592ba3e9638b28e45bed3901"
  litellm_postgres_image = "docker.io/postgres:18"
  litellm_host           = "litellm.home.shdr.ch"
  litellm_ns             = module.namespace["litellm"].name
  litellm_labels         = { app = "litellm" }
  litellm_port           = 4000
  litellm_postgres_port  = 5432
  litellm_cnpg_cluster   = "litellm-cnpg"
  litellm_db_host        = "${local.litellm_cnpg_cluster}-rw.${local.litellm_ns}.svc.cluster.local"
  litellm_config_yaml = templatefile("${path.module}/litellm_config.yaml.tftpl", {
    deskplane_mcp_auth_token   = var.deskplane_mcp_auth_token
    daimyo_mcp_exchange_secret = var.litellm_mcp_exchange_client_secret
    fm_mcp_token               = random_password.fm_mcp_token.result
    hyperdx_mcp_token          = var.secrets["hyperdx.api_key"]
    pharos_mcp_token           = random_password.pharos_mcp_token.result
    qbittorrent_mcp_token      = random_password.litellm_qbit_mcp.result
    sourcegull_mcp_token       = data.vault_kv_secret_v2.sourcegull_mcp.data["token"]
    x_bridge_mcp_token         = random_password.x_bridge_mcp_token.result
  })
  litellm_database_url  = "postgres://${var.secrets["litellm.database_user"]}:${var.secrets["litellm.database_password"]}@${local.litellm_db_host}/litellm?sslmode=disable"
  litellm_registry_host = "registry.gitlab.home.shdr.ch"
  litellm_registry_user = var.secrets["gitlab.root_email"]
  litellm_registry_pass = var.secrets["gitlab.root_password"]
}

resource "kubernetes_secret_v1" "litellm_env" {
  depends_on = [module.namespace["litellm"]]
  metadata {
    name      = "litellm-env"
    namespace = local.litellm_ns
  }

  data = {
    LITELLM_MASTER_KEY    = var.secrets["litellm.master_key"]
    DATABASE_URL          = local.litellm_database_url
    POSTGRES_DB           = "litellm"
    POSTGRES_USER         = var.secrets["litellm.database_user"]
    POSTGRES_PASSWORD     = var.secrets["litellm.database_password"]
    OLLAMA_API_KEY        = var.secrets["litellm.ollama_cloud_api_key"]
    CLINEPASS_API_KEY     = var.secrets["litellm.clinepass_api_key"]
    KIMI_API_KEY          = var.secrets["litellm.kimi_api_key"]
    QWEN_CLOUD_API_KEY    = var.secrets["litellm.qwen_cloud_api_key"]
    STEP_API_KEY          = var.secrets["litellm.step_api_key"]
    ZAI_API_KEY           = var.secrets["litellm.zai_api_key"]
    ZAI_SEVEN30_API_KEY   = var.secrets["litellm.zai_seven30_api_key"]
    COMMANDCODE_API_KEY   = var.secrets["litellm.commandcode_api_key"]
    OPENCODE_GO_API_KEY   = var.secrets["litellm.opencode_go_api_key"]
    OPENROUTER_API_KEY    = var.secrets["litellm.openrouter_api_key"]
    ROUTEWAY_API_KEY      = var.secrets["litellm.routeway_api_key"]
    XIAOMI_API_KEY        = var.secrets["litellm.xiaomi_api_key"]
    CODEBUDDY_API_KEY     = var.secrets["litellm.codebuddy_api_key"]
    ANTIGRAVITY_API_KEY   = random_password.antigravity_api_key.result
    MUSE_BRIDGE_API_KEY   = random_password.muse_bridge_api_key.result
    GROK_BRIDGE_API_KEY   = random_password.grok_bridge_api_key.result
    CLAUDE_BRIDGE_API_KEY = random_password.claude_bridge_api_key.result
    LITELLM_CONFIG_SHA    = sha256(local.litellm_config_yaml)
  }

  type = "Opaque"
}

# Bearer token the qbittorrent MCP server (mcp.tf) asks of its callers.
resource "random_password" "litellm_qbit_mcp" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "litellm_config" {
  depends_on = [module.namespace["litellm"]]
  metadata {
    name      = "litellm-config"
    namespace = local.litellm_ns
  }

  data = {
    "config.yaml"     = local.litellm_config_yaml
    "aether_hooks.py" = file("${path.module}/litellm_hooks.py")
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "litellm_gitlab_registry" {
  depends_on = [module.namespace["litellm"]]
  metadata {
    name      = "litellm-gitlab-registry"
    namespace = local.litellm_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.litellm_registry_host) = {
          username = local.litellm_registry_user
          password = local.litellm_registry_pass
          auth     = base64encode("${local.litellm_registry_user}:${local.litellm_registry_pass}")
        }
      }
    })
  }
}

# What the annas MCP server downloads. The server runs in the mcp namespace
# (mcp.tf) and mounts this claim's folder through a volume of its own; the
# claim stays here because it owns the folder.
resource "kubernetes_persistent_volume_claim_v1" "litellm_annas_downloads" {
  depends_on = [module.namespace["litellm"], kubernetes_storage_class_v1.nfs_hdd]

  metadata {
    name      = "annas-downloads"
    namespace = local.litellm_ns
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    resources {
      requests = { storage = "50Gi" }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# The same folder for the `orion` agent, read-only: its Agent mounts claim
# `annas-downloads` at /mnt/annas (Orion chart values, `mounts`), so it can
# open what the annas tools downloaded and hand an EPUB to Pharos as a tool
# file argument. A claim cannot be shared across namespaces, so this is a
# second, static volume over the dynamic volume's own NFS subdirectory (named
# after that volume, under the nfs-hdd share). The downloader writes its
# files world-readable; task pods run as uid 65534.
resource "kubernetes_persistent_volume_v1" "daimyo_personal_annas_downloads" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "personal-tasks-annas-downloads"
  }

  spec {
    capacity = { storage = "50Gi" }

    access_modes                     = ["ReadOnlyMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "personal-tasks-annas-downloads"
        read_only     = true
        volume_attributes = {
          server = var.nfs_server_ip
          share  = "/mnt/hdd/data/${kubernetes_persistent_volume_claim_v1.litellm_annas_downloads.spec[0].volume_name}"
        }
      }
    }

    mount_options = ["nfsvers=4.1", "hard", "nointr", "ro"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "daimyo_personal_annas_downloads" {
  depends_on = [module.namespace["personal-tasks"]]

  metadata {
    name      = "annas-downloads"
    namespace = "personal-tasks"
  }

  spec {
    access_modes       = ["ReadOnlyMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.daimyo_personal_annas_downloads.metadata[0].name

    resources {
      requests = { storage = "50Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "litellm_postgres_data" {
  depends_on = [module.namespace["litellm"], kubernetes_storage_class_v1.ceph_rbd]
  metadata {
    name      = "litellm-postgres-data"
    namespace = local.litellm_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_persistent_volume_claim_v1" "litellm_chatgpt_auth" {
  depends_on = [module.namespace["litellm"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "litellm-chatgpt-auth"
    namespace = local.litellm_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "litellm" {
  depends_on = [
    kubectl_manifest.litellm_cnpg_cluster,
    kubernetes_secret_v1.litellm_env,
    kubernetes_secret_v1.litellm_config,
    kubernetes_secret_v1.litellm_gitlab_registry,
  ]

  metadata {
    name      = "litellm"
    namespace = local.litellm_ns
    labels    = local.litellm_labels
  }

  spec {
    replicas = 1

    # The new pod comes up beside the old one and takes traffic only once
    # ready, so a config or image rollout is not a gateway outage (a turn
    # admitted during the old Recreate gap failed reading its spend). The
    # ChatGPT auth volume is RWO: the pod affinity below keeps the new pod on
    # the old one's node, where both can mount it.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }

    selector {
      match_labels = local.litellm_labels
    }

    template {
      metadata {
        labels = local.litellm_labels
        annotations = {
          "aether.shdr.ch/config-sha"       = sha256(local.litellm_config_yaml)
          "aether.shdr.ch/hooks-sha"        = filesha256("${path.module}/litellm_hooks.py")
          "aether.shdr.ch/database-url-sha" = sha256(local.litellm_database_url)
          "aether.shdr.ch/env-sha"          = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.litellm_env.data)))
        }
      }

      spec {
        enable_service_links = false

        # Co-locate with the running pod so the RWO litellm-chatgpt-auth
        # volume attaches to both during a rollout; a first pod with no peer
        # schedules anywhere.
        affinity {
          pod_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector { match_labels = local.litellm_labels }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.litellm_gitlab_registry.metadata[0].name
        }

        container {
          name  = "litellm"
          image = local.litellm_image
          args  = ["--config", "/app/config.yaml"]

          port {
            container_port = local.litellm_port
            name           = "http"
          }

          # Public origin for MCP OAuth (withings): the upstream redirects to
          # <origin>/callback, and the authorize endpoint's same-origin
          # redirect check otherwise resolves to the pod address.
          env {
            name  = "PROXY_BASE_URL"
            value = "https://${local.litellm_host}"
          }

          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "LITELLM_MASTER_KEY"
              }
            }
          }

          # LiteLLM 1.106 seals MCP pagination/continuation cursors with
          # LITELLM_SALT_KEY only (no master-key fallback). Stored DB secrets
          # are encrypted with the master key while no salt key is set, so the
          # salt key must be that same value or existing rows stop decrypting.
          env {
            name = "LITELLM_SALT_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "LITELLM_MASTER_KEY"
              }
            }
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }

          env {
            name  = "CHATGPT_TOKEN_DIR"
            value = "/var/lib/litellm/chatgpt"
          }

          env {
            name = "OLLAMA_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OLLAMA_API_KEY"
              }
            }
          }

          env {
            name = "CLINEPASS_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "CLINEPASS_API_KEY"
              }
            }
          }


          env {
            name = "QWEN_CLOUD_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "QWEN_CLOUD_API_KEY"
              }
            }
          }

          env {
            name = "STEP_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "STEP_API_KEY"
              }
            }
          }

          env {
            name = "ZAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ZAI_API_KEY"
              }
            }
          }

          env {
            name = "ZAI_SEVEN30_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ZAI_SEVEN30_API_KEY"
              }
            }
          }

          env {
            name = "COMMANDCODE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "COMMANDCODE_API_KEY"
              }
            }
          }

          env {
            name = "OPENCODE_GO_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OPENCODE_GO_API_KEY"
              }
            }
          }

          env {
            name = "OPENROUTER_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OPENROUTER_API_KEY"
              }
            }
          }

          env {
            name = "ROUTEWAY_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ROUTEWAY_API_KEY"
              }
            }
          }

          env {
            name = "XIAOMI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "XIAOMI_API_KEY"
              }
            }
          }

          env {
            name = "CODEBUDDY_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "CODEBUDDY_API_KEY"
              }
            }
          }


          env {
            name = "ANTIGRAVITY_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ANTIGRAVITY_API_KEY"
              }
            }
          }

          env {
            name = "MUSE_BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "MUSE_BRIDGE_API_KEY"
              }
            }
          }

          env {
            name = "GROK_BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "GROK_BRIDGE_API_KEY"
              }
            }
          }

          env {
            name = "CLAUDE_BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "CLAUDE_BRIDGE_API_KEY"
              }
            }
          }

          env {
            name = "LITELLM_CONFIG_SHA"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "LITELLM_CONFIG_SHA"
              }
            }
          }

          env {
            name = "KIMI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "KIMI_API_KEY"
              }
            }
          }

          # Moira decide service, called by the moira_router pre-call hook
          # (litellm_hooks.py) before deployment selection.
          env {
            name  = "MOIRA_DECIDE_URL"
            value = "http://moira.${local.litellm_ns}.svc.cluster.local:${local.moira_port}/decide"
          }

          env {
            name = "MOIRA_DECIDE_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.moira_env.metadata[0].name
                key  = "MOIRA_DECIDE_TOKEN"
              }
            }
          }

          # tiers.yaml `groups` names the hook sends to Moira; derived from the
          # same file the moira-config ConfigMap projects so it cannot drift.
          env {
            name  = "MOIRA_GROUPS"
            value = join(",", keys(local.moira_tiers.groups))
          }

          # Per-org routing exclusions, matched on the daimyo-minted key's
          # metadata.org (litellm_hooks.py). Cicada's agents must not draw the
          # operator's Claude subscription; every other caller is unaffected.
          env {
            name  = "MOIRA_ORG_EXCLUDED_PREFIXES"
            value = "cicada=claude/"
          }

          # Prisma migrations run before the server listens. Liveness killing a
          # migration mid-flight leaves a half-recorded migration that blocks
          # every later start (P3009, 2026-10-13: a lock wait outlasted the
          # liveness window). Liveness/readiness start only after this passes.
          startup_probe {
            http_get {
              path = "/health/liveliness"
              port = local.litellm_port
            }
            period_seconds    = 10
            failure_threshold = 90
          }

          readiness_probe {
            http_get {
              path = "/health/liveliness"
              port = local.litellm_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 12
          }

          liveness_probe {
            http_get {
              path = "/health/liveliness"
              port = local.litellm_port
            }
            initial_delay_seconds = 90
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "4000m"
              memory = "4Gi"
            }
          }

          volume_mount {
            name       = "litellm-config"
            mount_path = "/app/config.yaml"
            sub_path   = "config.yaml"
            read_only  = true
          }

          volume_mount {
            name       = "litellm-config"
            mount_path = "/app/aether_hooks.py"
            sub_path   = "aether_hooks.py"
            read_only  = true
          }

          volume_mount {
            name       = "chatgpt-auth"
            mount_path = "/var/lib/litellm"
          }
        }
        container {
          name  = "moira-chatgpt-usage"
          image = local.moira_image
          args  = ["chatgpt-usage"]

          # auth.json is root:root 0600 (LiteLLM runs as root), so the reader
          # must be uid 0; the image's non-numeric USER also fails
          # runAsNonRoot verification. No capabilities, read-only rootfs and
          # a read-only mount keep it a pure reader.
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_user                = 0
            run_as_group               = 0
            run_as_non_root            = false
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "CHATGPT_TOKEN_DIR"
            value = "/var/lib/litellm/chatgpt"
          }

          env {
            name  = "SIDECAR_PORT"
            value = tostring(local.moira_sidecar_port)
          }

          env {
            name = "MOIRA_SIDECAR_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.moira_env.metadata[0].name
                key  = "MOIRA_SIDECAR_TOKEN"
              }
            }
          }

          port {
            container_port = local.moira_sidecar_port
            name           = "moira-usage"
          }

          # No readiness probe: pod readiness gates the shared litellm
          # Service endpoints, so an unready sidecar removes the LLM
          # gateway for every consumer in the cluster. The liveness probe
          # below still restarts the sidecar if it hangs.

          liveness_probe {
            http_get {
              path = "/health"
              port = local.moira_sidecar_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "96Mi"
            }
          }

          volume_mount {
            name       = "chatgpt-auth"
            mount_path = "/var/lib/litellm"
            read_only  = true
          }
        }
        volume {
          name = "litellm-config"
          secret {
            secret_name = kubernetes_secret_v1.litellm_config.metadata[0].name
          }
        }
        volume {
          name = "chatgpt-auth"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.litellm_chatgpt_auth.metadata[0].name
          }
        }
      }
    }
  }


  lifecycle {
    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
      spec[0].template[0].spec[0].priority_class_name,
      # Preserve operator-requested restarts without causing a second rollout.
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
    ]
  }
}

resource "kubernetes_service_v1" "litellm" {
  depends_on = [kubernetes_deployment_v1.litellm]

  metadata {
    name      = "litellm"
    namespace = local.litellm_ns
    labels    = local.litellm_labels
  }

  spec {
    selector = local.litellm_labels

    port {
      port        = local.litellm_port
      target_port = local.litellm_port
      name        = "http"
    }

    # Moira's chatgpt-usage sidecar (moira.tf) reached by the moira-poller
    # through this Service for ChatGPT quota windows.
    port {
      port        = local.moira_sidecar_port
      target_port = local.moira_sidecar_port
      name        = "moira-usage"
    }
  }
}

resource "kubernetes_manifest" "litellm_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.litellm]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "litellm"
      namespace = local.litellm_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.litellm_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.litellm.metadata[0].name
          port = local.litellm_port
        }]
      }]
    }
  }
}
