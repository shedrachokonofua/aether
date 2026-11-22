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
  litellm_image               = "ghcr.io/berriai/litellm:v1.106.0-rc.1@sha256:de5b050c1e9bd7e6c0aebfa126c5df71de071962592ba3e9638b28e45bed3901"
  litellm_espn_mcp_image      = "registry.gitlab.home.shdr.ch/so/espn-mcp:latest"
  litellm_postgres_image      = "docker.io/postgres:18"
  litellm_finviz_image        = "registry.gitlab.home.shdr.ch/shdrch/finviz-mcp-server/main:latest"
  litellm_coingecko_image     = "docker.io/node:22-slim"
  litellm_time_mcp_image      = "docker.io/theo01/mcp-time:latest"
  litellm_google_maps_image   = "docker.io/node:22-slim"
  litellm_google_maps_package = "@cablate/mcp-google-map@0.0.52"
  litellm_tmdb_image          = "ghcr.io/cyanheads/tmdb-mcp-server:0.1.1"
  # Pinned: the mutable `mcp` tag moved to a build whose MCP SDK refuses a
  # 0.0.0.0 listener without MCP_ALLOWED_HOSTS/TLS, and a crashlooping
  # sidecar keeps the whole LiteLLM pod unready (2026-10-31 outage).
  litellm_jellyfin_mcp_image = "docker.io/knucklessg1/jellyfin-mcp:mcp@sha256:fc371dc6578e12eaba31710bfb447915ab1f4a12fd9005cc89dee77b745e43a2"
  # homeassistant-ai/ha-mcp 9.0.0 (ha-mcp-web, streamable HTTP). Admin token:
  # its 77 default tools include automation, dashboard, registry and system
  # edits; Orion's grant asks before those.
  litellm_ha_mcp_image = "ghcr.io/homeassistant-ai/ha-mcp:9.0.0@sha256:0298113732140c9d725171dc3f1dc5b6a53b03815482536ee2236e17e8cd1bdd"
  # qbittorrent-mcp-rs: granular tools (per-tool gateway and grant policy),
  # distroless multi-arch image. HTTP mode is SSE only, port 3000 hardcoded.
  litellm_qbit_mcp_image = "docker.io/nicholaswilde/qbittorrent-mcp-rs:0.3.9@sha256:f800f77f03d4ee3bcd98ff5cc07a8938197e8bdb1dde2f753af11e8459d8b1e3"
  # Karakeep's official MCP (@karakeep/mcp) is stdio-only; supergateway serves
  # it as stateless streamable HTTP, one karakeep-mcp process per request.
  litellm_karakeep_mcp_image    = "docker.io/node:22-slim"
  litellm_karakeep_mcp_packages = "@karakeep/mcp@0.34.0 supergateway@4.2.1"
  # cbcoutinho/nextcloud-mcp-server 0.213.2 (multi-arch index digest): native
  # streamable HTTP, single-user BasicAuth as Shedrach's Nextcloud account.
  litellm_nextcloud_mcp_image = "ghcr.io/cbcoutinho/nextcloud-mcp-server:0.213.2@sha256:655c2864b48fd3f0696480ebe19a165ff114a582b30b9cec1d6ab4923586d325"
  # pentafive/your-spotify-mcp v0.2.3 (commit 9e0e606, Apache-2.0, not on npm):
  # Your Spotify listening-history analytics, stdio-only. Built at start from
  # the commit tarball (sha256 checked) and served by supergateway like Karakeep.
  litellm_yourspotify_mcp_source = "https://codeload.github.com/pentafive/your-spotify-mcp/tar.gz/9e0e6068d2eebf7a0df697dee0df78667881c727"
  litellm_yourspotify_mcp_sha256 = "ff924bfcc3b61561ec79147fb0777b97608331e601e549151cdd7299319cc6fa"
  # iosifache/annas-mcp v0.1: stdio-only, bridged by mcp-proxy. Verify the
  # release archive before extracting the binary; downloads live on NFS HDD.
  litellm_annas_mcp_sha256 = {
    amd64 = "f457e204a4e6215e19b98910b7e30baff61f1f815c9fe2e8e344984cf55f68f2"
    arm64 = "789a27b12ae3105c7d1b4c4e31fb23fe57c7bba774417b23218a7cb9c88c1c50"
  }
  # cyanheads/pubmed-mcp-server 2.12.2: NCBI E-utilities PubMed/PMC server,
  # native streamable HTTP (multi-arch index digest). Read-only, keyless.
  litellm_pubmed_mcp_image = "ghcr.io/cyanheads/pubmed-mcp-server:2.12.2@sha256:18a156d2c0f6fa16332943dfb3fe89a09ba64cdd5757530d4015187d914a7721"
  # cyanheads/openfda-mcp-server 0.10.0: openFDA drug/device/food/tobacco
  # server, native streamable HTTP (multi-arch index digest). Read-only, keyless.
  litellm_openfda_mcp_image = "ghcr.io/cyanheads/openfda-mcp-server:0.10.0@sha256:6bade603ec477979f10c2d73289276c30dfd7958a84bbb29a232ab778970577a"
  # cyanheads/openalex-mcp-server 0.11.1: OpenAlex scholarly-works server,
  # native streamable HTTP (multi-arch index digest). Read-only; account key
  # (openalex.api_key) for the larger daily budget.
  litellm_openalex_mcp_image = "ghcr.io/cyanheads/openalex-mcp-server:0.11.1@sha256:7404b67e2203607ecb616b75f805d25f037b58f01859ca50b5f6281a4b23a780"
  # sourabhmadur/ticketmaster-mcp (commit bc3367d, tarball sha256 4825ec19...):
  # Ticketmaster Discovery API v2 events/attractions/venues, stdio only, so it
  # runs behind the same mcp-proxy bridge as comfy-mcp. Dependencies are pinned
  # explicitly (its own pins are open ranges); the base image by index digest.
  litellm_ticketmaster_mcp_image   = "docker.io/python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90"
  litellm_ticketmaster_mcp_package = "https://github.com/sourabhmadur/ticketmaster-mcp/archive/bc3367d251e5d1877f7222d23826a2bbe2be383e.tar.gz#sha256=4825ec19ecd764b6c76e1a977fe875c62fe0f27741c912129ae80881e0a99603"
  litellm_ticketmaster_mcp_deps    = "mcp==1.30.0 httpx==0.28.1 python-dotenv==1.2.4"
  # Official Comfy-Org comfy-mcp is stdio-only and needs mcp>=2; mcp-proxy
  # (mcp<2) bridges it to streamable HTTP, so each gets its own venv.
  litellm_comfy_mcp_image       = "docker.io/python:3.13-slim"
  litellm_comfy_mcp_packages    = "comfy-mcp==0.10.0 comfy-cli==1.22.0"
  litellm_mcp_proxy_package     = "mcp-proxy==0.13.0"
  litellm_host                  = "litellm.home.shdr.ch"
  litellm_espn_mcp_host         = "espn-mcp.home.shdr.ch"
  litellm_ns                    = module.namespace["litellm"].name
  litellm_labels                = { app = "litellm" }
  litellm_port                  = 4000
  litellm_finviz_port           = 8000
  litellm_coingecko_port        = 8002
  litellm_time_mcp_port         = 8003
  litellm_google_maps_port      = 8004
  litellm_tmdb_port             = 8006
  litellm_jellyfin_mcp_port     = 8007
  litellm_comfy_mcp_port        = 8008
  litellm_ha_mcp_port           = 8009
  litellm_karakeep_mcp_port     = 8010
  litellm_pubmed_mcp_port       = 8011
  litellm_ticketmaster_mcp_port = 8012
  litellm_openfda_mcp_port      = 8013
  litellm_openalex_mcp_port     = 8014
  litellm_yourspotify_mcp_port  = 8015
  litellm_annas_mcp_port        = 8016
  litellm_nextcloud_mcp_port    = 8017
  litellm_qbit_mcp_port         = 3000
  litellm_espn_mcp_port         = 8080
  litellm_postgres_port         = 5432
  litellm_cnpg_cluster          = "litellm-cnpg"
  litellm_db_host               = "${local.litellm_cnpg_cluster}-rw.${local.litellm_ns}.svc.cluster.local"
  litellm_config_yaml = templatefile("${path.module}/litellm_config.yaml.tftpl", {
    deskplane_mcp_auth_token   = var.deskplane_mcp_auth_token
    daimyo_mcp_exchange_secret = var.litellm_mcp_exchange_client_secret
    fm_mcp_token               = random_password.fm_mcp_token.result
    hyperdx_mcp_token          = var.secrets["hyperdx.api_key"]
    google_maps_enabled        = var.litellm_google_maps_enabled
    pharos_mcp_token           = random_password.pharos_mcp_token.result
    qbittorrent_mcp_token      = random_password.litellm_qbit_mcp.result
    sourcegull_mcp_token       = data.vault_kv_secret_v2.sourcegull_mcp.data["token"]
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

  data = merge(
    {
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
      FINVIZ_API_KEY        = var.secrets["finviz_api_key"]
      COINGECKO_API_KEY     = var.secrets["coingecko_api_key"]
      TMDB_API_KEY          = var.secrets["tmdb_read_access_token"]
      JELLYFIN_API_KEY      = var.secrets["jellyfin.beryl_api_key"]
      # Reuses the Prometheus scrape token (owner account): ha-mcp's edits
      # log under that user, and rotating it breaks both consumers.
      HOMEASSISTANT_TOKEN    = var.secrets["homeassistant.telemetry_token"]
      KARAKEEP_API_KEY       = var.secrets["karakeep.mcp_api_key"]
      NEXTCLOUD_MCP_PASSWORD = random_password.nextcloud_mcp_app_password.result
      TICKETMASTER_API_KEY   = var.secrets["ticketmaster.api_key"]
      OPENALEX_API_KEY       = var.secrets["openalex.api_key"]
      YOUR_SPOTIFY_TOKEN     = var.secrets["yourspotify.mcp_public_token"]
      ANNAS_SECRET_KEY       = var.secrets["annas_archive.secret_key"]
      QBIT_MCP_USERNAME      = var.secrets["qbittorrent.username"]
      QBIT_MCP_PASSWORD      = var.secrets["qbittorrent.password"]
      QBIT_MCP_HTTP_TOKEN    = random_password.litellm_qbit_mcp.result
      LITELLM_CONFIG_SHA     = sha256(local.litellm_config_yaml)
    },
    var.litellm_google_maps_enabled ? {
      GOOGLE_MAPS_API_KEY = var.litellm_google_maps_api_key
    } : {}
  )

  type = "Opaque"
}

# Bearer token LiteLLM presents to the qbittorrent-mcp sidecar, which listens
# on the pod IP (0.0.0.0:3000 is hardcoded upstream).
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
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
      # Only our GitLab sidecars auto-update; third-party :latest sidecars
      # (mcp-time, node-based) are excluded by container-name regex.
      "keel.sh/monitorContainers" = "^(espn-mcp|finviz-mcp-server)$"
    }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
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
          name              = "finviz-mcp-server"
          image             = local.litellm_finviz_image
          image_pull_policy = "Always"

          port {
            container_port = local.litellm_finviz_port
            name           = "finviz"
          }

          env {
            name  = "MCP_TRANSPORT"
            value = "streamable-http"
          }

          env {
            name  = "MCP_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "MCP_PORT"
            value = tostring(local.litellm_finviz_port)
          }

          env {
            name = "FINVIZ_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "FINVIZ_API_KEY"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        container {
          name    = "coingecko-mcp-server"
          image   = local.litellm_coingecko_image
          command = ["npx", "-y", "@coingecko/coingecko-mcp", "--transport", "http", "--port", tostring(local.litellm_coingecko_port)]

          port {
            container_port = local.litellm_coingecko_port
            name           = "coingecko"
          }

          env {
            name = "COINGECKO_DEMO_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "COINGECKO_API_KEY"
              }
            }
          }

          env {
            name  = "COINGECKO_ENVIRONMENT"
            value = "demo"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }

        container {
          name  = "time-mcp-server"
          image = local.litellm_time_mcp_image
          args  = ["--transport", "stream", "--address", "http://0.0.0.0:${local.litellm_time_mcp_port}/mcp"]

          port {
            container_port = local.litellm_time_mcp_port
            name           = "time-mcp"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        dynamic "container" {
          for_each = var.litellm_google_maps_enabled ? [1] : []

          content {
            name    = "google-maps-mcp-server"
            image   = local.litellm_google_maps_image
            command = ["npx", "-y", local.litellm_google_maps_package, "--host", "0.0.0.0", "--port", tostring(local.litellm_google_maps_port)]

            port {
              container_port = local.litellm_google_maps_port
              name           = "google-maps"
            }

            env {
              name = "GOOGLE_MAPS_API_KEY"
              value_from {
                secret_key_ref {
                  name = kubernetes_secret_v1.litellm_env.metadata[0].name
                  key  = "GOOGLE_MAPS_API_KEY"
                }
              }
            }

            resources {
              requests = {
                cpu    = "50m"
                memory = "512Mi"
              }
              limits = {
                cpu    = "500m"
                memory = "1Gi"
              }
            }
          }
        }

        container {
          name              = "espn-mcp"
          image             = local.litellm_espn_mcp_image
          command           = ["espn-mcp", "--http", "8080"]
          image_pull_policy = "Always"

          port {
            name           = "espn-mcp"
            container_port = local.litellm_espn_mcp_port
            protocol       = "TCP"
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.litellm_espn_mcp_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.litellm_espn_mcp_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        container {
          name  = "tmdb-mcp-server"
          image = local.litellm_tmdb_image
          # Native Streamable HTTP; auth is TMDB v4 Read Access Token (Bearer).

          port {
            container_port = local.litellm_tmdb_port
            name           = "tmdb-mcp"
          }

          env {
            name  = "MCP_TRANSPORT_TYPE"
            value = "http"
          }

          env {
            name  = "MCP_HTTP_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "MCP_HTTP_PORT"
            value = tostring(local.litellm_tmdb_port)
          }

          env {
            name  = "MCP_AUTH_MODE"
            value = "none"
          }

          env {
            name  = "MCP_LOG_LEVEL"
            value = "info"
          }

          env {
            name = "TMDB_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "TMDB_API_KEY"
              }
            }
          }


          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.litellm_tmdb_port
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 12
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.litellm_tmdb_port
            }
            initial_delay_seconds = 45
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }
        container {
          name  = "pubmed-mcp"
          image = local.litellm_pubmed_mcp_image
          # Native Streamable HTTP, stateless. Loopback only: no auth here and
          # only LiteLLM calls it. Keyless NCBI E-utilities (3 req/s, paced by
          # the server's own request queue); no secrets. Unpaywall stays off
          # because UNPAYWALL_EMAIL is unset.

          env {
            name  = "MCP_TRANSPORT_TYPE"
            value = "http"
          }

          env {
            name  = "MCP_HTTP_HOST"
            value = "127.0.0.1"
          }

          env {
            name  = "MCP_HTTP_PORT"
            value = tostring(local.litellm_pubmed_mcp_port)
          }

          env {
            name  = "MCP_SESSION_MODE"
            value = "stateless"
          }

          env {
            name  = "MCP_AUTH_MODE"
            value = "none"
          }

          env {
            name  = "MCP_LOG_LEVEL"
            value = "info"
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          readiness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.litellm_pubmed_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.litellm_pubmed_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 45
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        container {
          name  = "openfda-mcp"
          image = local.litellm_openfda_mcp_image
          # Native Streamable HTTP, stateless. Loopback only: no auth here and
          # only LiteLLM calls it. Keyless openFDA (1K requests/day per IP;
          # OPENFDA_API_KEY unset); no secrets. DataCanvas staging is off, but
          # the server still lists the openfda_dataframe_* tools (they answer
          # canvas_disabled), so the gateway allowlists the 12 real tools.

          env {
            name  = "MCP_TRANSPORT_TYPE"
            value = "http"
          }

          env {
            name  = "MCP_HTTP_HOST"
            value = "127.0.0.1"
          }

          env {
            name  = "MCP_HTTP_PORT"
            value = tostring(local.litellm_openfda_mcp_port)
          }

          env {
            name  = "MCP_SESSION_MODE"
            value = "stateless"
          }

          env {
            name  = "MCP_AUTH_MODE"
            value = "none"
          }

          env {
            name  = "MCP_LOG_LEVEL"
            value = "info"
          }

          env {
            name  = "CANVAS_PROVIDER_TYPE"
            value = "none"
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          readiness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.litellm_openfda_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.litellm_openfda_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 45
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        container {
          name  = "openalex-mcp"
          image = local.litellm_openalex_mcp_image
          # Native Streamable HTTP, stateless. Loopback only: no auth here and
          # only LiteLLM calls it. OPENALEX_API_KEY is Shedrach's free OpenAlex
          # account key (sops openalex.api_key: $1/day budget, 10K credits on
          # 2026-11-15, against the anonymous tier); OPENALEX_MAILTO unset.

          env {
            name  = "MCP_TRANSPORT_TYPE"
            value = "http"
          }

          env {
            name  = "MCP_HTTP_HOST"
            value = "127.0.0.1"
          }

          env {
            name  = "MCP_HTTP_PORT"
            value = tostring(local.litellm_openalex_mcp_port)
          }

          env {
            name  = "MCP_SESSION_MODE"
            value = "stateless"
          }

          env {
            name  = "MCP_AUTH_MODE"
            value = "none"
          }

          env {
            name  = "MCP_LOG_LEVEL"
            value = "info"
          }

          env {
            name = "OPENALEX_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OPENALEX_API_KEY"
              }
            }
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          readiness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.litellm_openalex_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.litellm_openalex_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 45
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        container {
          name  = "ticketmaster-mcp"
          image = local.litellm_ticketmaster_mcp_image
          # Loopback only: mcp-proxy has no auth here and only LiteLLM calls
          # it. The server is stdio-only; mcp-proxy serves it as streamable
          # HTTP (one stdio child per session). Read-only Discovery API v2 (6
          # tools, no purchase flow). The consumer key reaches the child as
          # TICKETMASTER_API_KEY via --pass-environment and is never a tool
          # argument. It travels in the Discovery request query string, so the
          # child's httpx request logger is raised to WARNING to keep the key
          # out of container logs.
          command = ["sh", "-c", <<-EOT
            set -e
            python -m venv /opt/tm && /opt/tm/bin/pip install --no-cache-dir --quiet ${local.litellm_ticketmaster_mcp_deps} "${local.litellm_ticketmaster_mcp_package}"
            python -m venv /opt/proxy && /opt/proxy/bin/pip install --no-cache-dir --quiet ${local.litellm_mcp_proxy_package}
            exec /opt/proxy/bin/mcp-proxy --host 127.0.0.1 --port ${local.litellm_ticketmaster_mcp_port} --pass-environment -- /opt/tm/bin/python -c 'import logging; logging.getLogger("httpx").setLevel(logging.WARNING); from ticketmaster_mcp.server import main; main()'
          EOT
          ]

          env {
            name = "TICKETMASTER_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "TICKETMASTER_API_KEY"
              }
            }
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_ticketmaster_mcp_port}/status', timeout=4)"]
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 18
          }

          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_ticketmaster_mcp_port}/status', timeout=4)"]
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        container {
          name  = "jellyfin-mcp"
          image = local.litellm_jellyfin_mcp_image
          # Native Streamable HTTP; auth is a dedicated Jellyfin API key.
          # Condensed mode: 3 action-routed tools instead of 368 1:1 API tools.

          port {
            container_port = local.litellm_jellyfin_mcp_port
            name           = "jellyfin-mcp"
          }

          env {
            name  = "TRANSPORT"
            value = "streamable-http"
          }

          env {
            name  = "HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "PORT"
            value = tostring(local.litellm_jellyfin_mcp_port)
          }

          env {
            name  = "MCP_TOOL_MODE"
            value = "condensed"
          }

          env {
            name  = "ENABLE_OTEL"
            value = "False"
          }

          env {
            name  = "JELLYFIN_URL"
            value = "http://jellyfin.${local.jellyfin_ns}.svc.cluster.local:${local.jellyfin_port}"
          }

          env {
            name = "JELLYFIN_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "JELLYFIN_API_KEY"
              }
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.litellm_jellyfin_mcp_port
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 12
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.litellm_jellyfin_mcp_port
            }
            initial_delay_seconds = 45
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }
        container {
          name  = "ha-mcp"
          image = local.litellm_ha_mcp_image
          # Loopback only, like comfy-mcp: standard-mode HTTP has no auth
          # beyond the URL path, and the only client is the LiteLLM
          # container in this pod. Home Assistant's API goes through the home
          # Caddy (ha.home.shdr.ch), so the admin token never crosses the LAN
          # in plaintext.
          command = ["ha-mcp-web"]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 999
            run_as_group               = 999
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "HOMEASSISTANT_URL"
            value = "https://ha.home.shdr.ch"
          }

          env {
            name = "HOMEASSISTANT_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "HOMEASSISTANT_TOKEN"
              }
            }
          }

          env {
            name  = "MCP_HOST"
            value = "127.0.0.1"
          }

          env {
            name  = "MCP_PORT"
            value = tostring(local.litellm_ha_mcp_port)
          }

          # Unauthenticated {"status":"ok"} for the exec probes below.
          env {
            name  = "MCP_HEALTHZ"
            value = "true"
          }

          # The settings UI can re-enable tools and flip safety flags; this
          # file is the only configuration.
          env {
            name  = "HA_MCP_DISABLE_SETTINGS_UI"
            value = "true"
          }

          env {
            name  = "HA_MCP_DISABLE_UPDATE_CHECK"
            value = "true"
          }

          # Otherwise a startup pass can opt itself in and ask HACS to refresh
          # repositories on every restart.
          env {
            name  = "HAMCP_HACS_REFRESH_AFTER_UPDATE"
            value = "false"
          }

          # Tool config and the pre-edit auto-backups (ha_manage_backup
          # restores them). emptyDir: they last for the pod's lifetime only.
          env {
            name  = "HA_MCP_CONFIG_DIR"
            value = "/data"
          }

          volume_mount {
            name       = "ha-mcp-data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "ha-mcp-tmp"
            mount_path = "/tmp"
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_ha_mcp_port}/healthz', timeout=5)"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 6
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_ha_mcp_port}/healthz', timeout=5)"]
            }
            initial_delay_seconds = 45
            period_seconds        = 30
            timeout_seconds       = 6
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "192Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "768Mi"
            }
          }
        }
        container {
          name  = "karakeep-mcp"
          image = local.litellm_karakeep_mcp_image
          # Loopback only: supergateway has no auth here, and the API key
          # acts as Shedrach's Karakeep account. Only LiteLLM calls it.
          command = ["sh", "-c", <<-EOT
            set -e
            npm install -g --no-fund --no-audit --loglevel=error ${local.litellm_karakeep_mcp_packages}
            exec supergateway --stdio karakeep-mcp --outputTransport streamableHttp --host 127.0.0.1 --port ${local.litellm_karakeep_mcp_port} --healthEndpoint /healthz
          EOT
          ]

          env {
            name  = "KARAKEEP_API_ADDR"
            value = "http://karakeep.${local.karakeep_ns}.svc.cluster.local:${local.karakeep_port}"
          }

          env {
            name = "KARAKEEP_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "KARAKEEP_API_KEY"
              }
            }
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          readiness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.litellm_karakeep_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 18
          }

          liveness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.litellm_karakeep_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        container {
          name  = "nextcloud-mcp"
          image = local.litellm_nextcloud_mcp_image
          # Loopback only: no auth here and only LiteLLM calls it. Signs in to
          # Nextcloud as Shedrach's account with a dedicated app password
          # (nextcloud.tf), so it reaches everything he can. Only the Files,
          # Sharing, Calendar and Contacts tools register; semantic search
          # stays off (the default).
          command = [
            "/opt/venv/bin/nextcloud-mcp-server", "run",
            "--host", "127.0.0.1",
            "--port", tostring(local.litellm_nextcloud_mcp_port),
            "--transport", "streamable-http",
            "--enable-app", "webdav",
            "--enable-app", "sharing",
            "--enable-app", "calendar",
            "--enable-app", "contacts",
          ]

          env {
            name  = "NEXTCLOUD_HOST"
            value = "http://nextcloud-server.${local.nextcloud_namespace}.svc.cluster.local"
          }

          # Browser-facing base for the deep links in tool results.
          env {
            name  = "NEXTCLOUD_PUBLIC_URL"
            value = "https://${local.nextcloud_host}"
          }

          env {
            name  = "NEXTCLOUD_USERNAME"
            value = local.nextcloud_mcp_uid
          }

          env {
            name = "NEXTCLOUD_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "NEXTCLOUD_MCP_PASSWORD"
              }
            }
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          # Neither endpoint calls Nextcloud, so its outages do not restart
          # this container or unready the LiteLLM pod.
          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_nextcloud_mcp_port}/health/ready', timeout=4)"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 18
          }

          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_nextcloud_mcp_port}/health/live', timeout=4)"]
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }
        container {
          name  = "yourspotify-mcp"
          image = local.litellm_karakeep_mcp_image
          # Loopback only: supergateway has no auth here. YOUR_SPOTIFY_TOKEN is
          # Your Spotify's public (share) token: it reads Shedrach's stats and
          # is sent as ?token=, so the server logs no requests. No Spotify Web
          # API credentials, so the playback/playlist tools never register.
          command = ["sh", "-c", <<-EOT
            set -e
            cd /tmp
            node -e "fetch('${local.litellm_yourspotify_mcp_source}').then(r => { if (!r.ok) throw new Error(r.status); return r.arrayBuffer(); }).then(b => require('fs').writeFileSync('src.tgz', Buffer.from(b)))"
            echo "${local.litellm_yourspotify_mcp_sha256}  src.tgz" | sha256sum -c -
            rm -rf app && mkdir app && tar xzf src.tgz -C app --strip-components=1
            cd app
            npm ci --no-fund --no-audit --loglevel=error
            npm run build --silent
            npm install -g --no-fund --no-audit --loglevel=error supergateway@4.2.1
            exec supergateway --stdio "node /tmp/app/build/index.js" --outputTransport streamableHttp --host 127.0.0.1 --port ${local.litellm_yourspotify_mcp_port} --healthEndpoint /healthz
          EOT
          ]

          env {
            name  = "YOUR_SPOTIFY_API_URL"
            value = "http://yourspotify-api.${local.yourspotify_ns}.svc.cluster.local:${local.yourspotify_api_port}"
          }

          env {
            name = "YOUR_SPOTIFY_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "YOUR_SPOTIFY_TOKEN"
              }
            }
          }

          # Loopback bind: httpGet probes dial the pod IP, so probe from inside.
          readiness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.litellm_yourspotify_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30
          }

          liveness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.litellm_yourspotify_mcp_port}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 300
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
        }
        container {
          name  = "annas-mcp"
          image = local.litellm_ticketmaster_mcp_image
          # Loopback bridge, like Ticketmaster. Pin the mirror: automatic
          # discovery sends membership requests to third-party-selected hosts.
          command = ["sh", "-c", <<-EOT
            set -e
            python - <<'PY'
            import hashlib, io, os, platform, tarfile, urllib.request
            arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
            expected = ${jsonencode(local.litellm_annas_mcp_sha256)}
            name = "annas-mcp_0.1_linux_" + arch
            url = "https://github.com/iosifache/annas-mcp/releases/download/v0.1/" + name + ".tar.xz"
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != expected[arch]:
                raise RuntimeError("Anna's MCP release checksum mismatch")
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as archive:
                with archive.extractfile(name + "/annas-mcp") as source, open("/opt/annas-mcp", "wb") as target:
                    target.write(source.read())
            os.chmod("/opt/annas-mcp", 0o755)
            PY
            python -m venv /opt/proxy && /opt/proxy/bin/pip install --no-cache-dir --quiet ${local.litellm_mcp_proxy_package}
            exec /opt/proxy/bin/mcp-proxy --host 127.0.0.1 --port ${local.litellm_annas_mcp_port} --pass-environment -- /opt/annas-mcp --timeout 60s mcp
          EOT
          ]

          env {
            name  = "ANNAS_BASE_URL"
            value = "annas-archive.gl"
          }
          env {
            name  = "ANNAS_DOWNLOAD_PATH"
            value = "/downloads"
          }
          env {
            name = "ANNAS_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ANNAS_SECRET_KEY"
              }
            }
          }

          volume_mount {
            name       = "annas-downloads"
            mount_path = "/downloads"
          }

          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_annas_mcp_port}/status', timeout=4)"]
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30
          }
          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.litellm_annas_mcp_port}/status', timeout=4)"]
            }
            initial_delay_seconds = 300
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
        container {
          name  = "qbittorrent-mcp"
          image = local.litellm_qbit_mcp_image
          # SSE MCP on 0.0.0.0:3000 (hardcoded), bearer-token gated; logs in to
          # the WebUI with the exporter's credentials. Env keys are
          # QBITTORRENT_ + config key, so the instance fields carry a second
          # QBITTORRENT_ (upstream README's QBITTORRENT_HOST is ignored).

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 65532
            run_as_group               = 65532
            capabilities { drop = ["ALL"] }
          }

          port {
            container_port = local.litellm_qbit_mcp_port
            name           = "qbit-mcp"
          }

          env {
            name  = "QBITTORRENT_SERVER_MODE"
            value = "http"
          }

          env {
            name  = "QBITTORRENT_QBITTORRENT_HOST"
            value = "http://qbittorrent.${local.qbittorrent_ns}.svc.cluster.local:${local.qbittorrent_port}"
          }

          # Re-login only happens in this sync poll, so it bounds recovery
          # after a qBittorrent restart; it also keeps the WebUI session warm.
          env {
            name  = "QBITTORRENT_POLLING_INTERVAL_MS"
            value = "10000"
          }

          env {
            name = "QBITTORRENT_QBITTORRENT_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "QBIT_MCP_USERNAME"
              }
            }
          }

          env {
            name = "QBITTORRENT_QBITTORRENT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "QBIT_MCP_PASSWORD"
              }
            }
          }

          env {
            name = "QBITTORRENT_HTTP_AUTH_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "QBIT_MCP_HTTP_TOKEN"
              }
            }
          }

          # No health endpoint and /sse needs the token: probe the socket.
          readiness_probe {
            tcp_socket {
              port = local.litellm_qbit_mcp_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 6
          }

          liveness_probe {
            tcp_socket {
              port = local.litellm_qbit_mcp_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
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
          # Service endpoints, so an unready MCP sidecar removes the LLM
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

        container {
          name  = "comfy-mcp"
          image = local.litellm_comfy_mcp_image
          # Loopback only: the tools submit arbitrary ComfyUI workflows, so the
          # only client is the LiteLLM container in this pod.
          #
          # comfy-cli refuses to read /object_info from a non-loopback host in
          # local mode (its SSRF guard), which breaks generate_image,
          # run_template --param, nodes, validate and the slot tools. A TCP
          # forwarder on 127.0.0.1:8188 to the in-cluster ComfyUI makes it the
          # default local target, so no COMFY_LOCAL_URL/COMFYUI_URL is set.
          # COMFY_API_KEY is deliberately unset so partner (paid) nodes cannot
          # spend.
          command = ["sh", "-c", <<-EOT
            set -e
            python -m venv /opt/comfy && /opt/comfy/bin/pip install --no-cache-dir --quiet ${local.litellm_comfy_mcp_packages}
            python -m venv /opt/proxy && /opt/proxy/bin/pip install --no-cache-dir --quiet ${local.litellm_mcp_proxy_package}
            cat > /opt/forward.py <<'PY'
            import asyncio

            UPSTREAM = ("comfyui.${local.comfyui_ns}.svc.cluster.local", ${local.comfyui_port})

            async def pipe(reader, writer):
                try:
                    while data := await reader.read(65536):
                        writer.write(data)
                        await writer.drain()
                finally:
                    writer.close()

            async def handle(client_reader, client_writer):
                try:
                    up_reader, up_writer = await asyncio.open_connection(*UPSTREAM)
                except OSError:
                    client_writer.close()
                    return
                await asyncio.gather(pipe(client_reader, up_writer), pipe(up_reader, client_writer), return_exceptions=True)

            async def main():
                server = await asyncio.start_server(handle, "127.0.0.1", ${local.comfyui_port})
                async with server:
                    await server.serve_forever()

            asyncio.run(main())
            PY
            python /opt/forward.py &
            exec /opt/proxy/bin/mcp-proxy --host 127.0.0.1 --port ${local.litellm_comfy_mcp_port} --pass-environment -- /opt/comfy/bin/comfy-mcp
          EOT
          ]

          env {
            name  = "COMFY_BIN"
            value = "/opt/comfy/bin/comfy"
          }

          # comfy-cli imports GitPython; the slim image has no git binary.
          env {
            name  = "GIT_PYTHON_REFRESH"
            value = "quiet"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
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
        volume {
          name = "annas-downloads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.litellm_annas_downloads.metadata[0].name
          }
        }
        volume {
          name = "ha-mcp-data"
          empty_dir {
            size_limit = "256Mi"
          }
        }
        volume {
          name = "ha-mcp-tmp"
          empty_dir {
            size_limit = "64Mi"
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

# Direct access to the espn-mcp sidecar for dev testing, bypassing litellm.
# Selects the litellm pod and targets the sidecar's 8080 port by name.
resource "kubernetes_service_v1" "litellm_espn_mcp" {
  depends_on = [kubernetes_deployment_v1.litellm]

  metadata {
    name      = "espn-mcp"
    namespace = local.litellm_ns
    labels    = local.litellm_labels
  }

  spec {
    selector = local.litellm_labels

    port {
      port        = local.litellm_espn_mcp_port
      target_port = "espn-mcp"
      name        = "espn-mcp"
    }
  }
}

resource "kubernetes_manifest" "litellm_espn_mcp_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.litellm_espn_mcp]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "espn-mcp"
      namespace = local.litellm_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.litellm_espn_mcp_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.litellm_espn_mcp.metadata[0].name
          port = local.litellm_espn_mcp_port
        }]
      }]
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
