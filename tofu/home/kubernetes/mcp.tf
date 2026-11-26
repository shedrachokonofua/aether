# =============================================================================
# MCP tool servers
# =============================================================================
# Each third-party MCP server runs here as its own Deployment and Service:
# `http://<server>.mcp.svc.cluster.local:<port>`. They were containers in
# LiteLLM's pod, where one that would not start kept the model gateway unready
# (2026-10-31), and where listening on loopback was the only thing keeping
# other pods out.
#
# None of them asks its caller to sign in (qbittorrent takes a bearer token),
# so the namespace admits only Meridian, and LiteLLM to the servers it still
# routes to (mcp_cilium_network). A
# server holds its own upstream credential and nothing else: one Secret each,
# no Kubernetes API token.
#
# A server that only speaks stdio is put on HTTP inside its container by
# supergateway (Node) or mcp-proxy (Python).

locals {
  mcp_namespace = module.namespace["mcp"].name

  # Whether the Google Maps server runs. The variable is marked sensitive only
  # because it arrives beside the API key.
  mcp_google_maps = nonsensitive(var.litellm_google_maps_enabled)

  # Port each server listens on, by server name.
  mcp_port = merge(
    {
      annas         = 8016
      comfyui       = 8008
      espn          = 8080
      finviz        = 8000
      homeassistant = 8009
      jellyfin      = 8007
      karakeep      = 8010
      nextcloud     = 8017
      openalex      = 8014
      openfda       = 8013
      pubmed        = 8011
      qbittorrent   = 3000
      ticketmaster  = 8012
      time          = 8003
      tmdb          = 8006
      yourspotify   = 8015
    },
    local.mcp_google_maps ? { google-maps = 8004 } : {},
  )

  # The servers LiteLLM still routes to (litellm_config.yaml.tftpl
  # mcp_servers): the ones OpenWebUI's and Foundry's keys may use, and
  # qbittorrent, whose SSE Meridian does not speak.
  mcp_litellm_routes = ["comfyui", "espn", "finviz", "google-maps", "jellyfin", "qbittorrent", "time", "tmdb"]

  # The upstream credential each server is given, by server name.
  mcp_secrets = merge(
    {
      annas = {
        ANNAS_SECRET_KEY = var.secrets["annas_archive.secret_key"]
      }
      finviz = {
        FINVIZ_API_KEY = var.secrets["finviz_api_key"]
      }
      homeassistant = {
        # Reuses the Prometheus scrape token (owner account): the server's
        # edits log under that user, and rotating it breaks both consumers.
        HOMEASSISTANT_TOKEN = var.secrets["homeassistant.telemetry_token"]
      }
      jellyfin = {
        JELLYFIN_API_KEY = var.secrets["jellyfin.beryl_api_key"]
      }
      karakeep = {
        KARAKEEP_API_KEY = var.secrets["karakeep.mcp_api_key"]
      }
      nextcloud = {
        NEXTCLOUD_MCP_PASSWORD = random_password.nextcloud_mcp_app_password.result
      }
      openalex = {
        OPENALEX_API_KEY = var.secrets["openalex.api_key"]
      }
      qbittorrent = {
        QBIT_MCP_USERNAME   = var.secrets["qbittorrent.username"]
        QBIT_MCP_PASSWORD   = var.secrets["qbittorrent.password"]
        QBIT_MCP_HTTP_TOKEN = random_password.litellm_qbit_mcp.result
      }
      ticketmaster = {
        TICKETMASTER_API_KEY = var.secrets["ticketmaster.api_key"]
      }
      tmdb = {
        TMDB_API_KEY = var.secrets["tmdb_read_access_token"]
      }
      yourspotify = {
        YOUR_SPOTIFY_TOKEN = var.secrets["yourspotify.mcp_public_token"]
      }
    },
    local.mcp_google_maps ? {
      google-maps = {
        GOOGLE_MAPS_API_KEY = var.litellm_google_maps_api_key
      }
    } : {},
  )

  mcp_espn_image          = "registry.gitlab.home.shdr.ch/so/espn-mcp:latest"
  mcp_finviz_image        = "registry.gitlab.home.shdr.ch/shdrch/finviz-mcp-server/main:latest"
  mcp_time_image          = "docker.io/theo01/mcp-time:latest"
  mcp_google_maps_image   = "docker.io/node:22-slim"
  mcp_google_maps_package = "@cablate/mcp-google-map@0.0.52"
  mcp_tmdb_image          = "ghcr.io/cyanheads/tmdb-mcp-server:0.1.1"
  # Pinned: the mutable `mcp` tag moved to a build whose MCP SDK refuses a
  # 0.0.0.0 listener without MCP_ALLOWED_HOSTS/TLS, and crashlooped
  # (2026-10-31).
  mcp_jellyfin_image = "docker.io/knucklessg1/jellyfin-mcp:mcp@sha256:fc371dc6578e12eaba31710bfb447915ab1f4a12fd9005cc89dee77b745e43a2"
  # homeassistant-ai/ha-mcp 9.0.0 (ha-mcp-web, streamable HTTP). Admin token:
  # its 77 default tools include automation, dashboard, registry and system
  # edits; Orion's grant asks before those.
  mcp_homeassistant_image = "ghcr.io/homeassistant-ai/ha-mcp:9.0.0@sha256:0298113732140c9d725171dc3f1dc5b6a53b03815482536ee2236e17e8cd1bdd"
  # qbittorrent-mcp-rs: granular tools (per-tool gateway and grant policy),
  # distroless multi-arch image. HTTP mode is SSE only, port 3000 hardcoded.
  mcp_qbittorrent_image = "docker.io/nicholaswilde/qbittorrent-mcp-rs:0.3.9@sha256:f800f77f03d4ee3bcd98ff5cc07a8938197e8bdb1dde2f753af11e8459d8b1e3"
  # Karakeep's official MCP (@karakeep/mcp) is stdio-only; supergateway serves
  # it as stateless streamable HTTP, one karakeep-mcp process per request.
  mcp_karakeep_image    = "docker.io/node:22-slim"
  mcp_karakeep_packages = "@karakeep/mcp@0.34.0 supergateway@4.2.1"
  # cbcoutinho/nextcloud-mcp-server 0.213.2 (multi-arch index digest): native
  # streamable HTTP, single-user BasicAuth as Shedrach's Nextcloud account.
  mcp_nextcloud_image = "ghcr.io/cbcoutinho/nextcloud-mcp-server:0.213.2@sha256:655c2864b48fd3f0696480ebe19a165ff114a582b30b9cec1d6ab4923586d325"
  # pentafive/your-spotify-mcp v0.2.3 (commit 9e0e606, Apache-2.0, not on npm):
  # Your Spotify listening-history analytics, stdio-only. Built at start from
  # the commit tarball (sha256 checked) and served by supergateway like Karakeep.
  mcp_yourspotify_source = "https://codeload.github.com/pentafive/your-spotify-mcp/tar.gz/9e0e6068d2eebf7a0df697dee0df78667881c727"
  mcp_yourspotify_sha256 = "ff924bfcc3b61561ec79147fb0777b97608331e601e549151cdd7299319cc6fa"
  # SokolskyNikita/annas-mcp v0.8.2 (MIT): stdio-only, bridged by mcp-proxy.
  # It replaced iosifache/annas-mcp v0.1 on 2026-11-24: Anna's Archive put
  # search behind a DDoS-Guard browser check, v0.1 scraped the page signed
  # out and answered "No books found" to every query. This one signs in with
  # the membership key (search needs Lucky Librarian or higher) and keeps the
  # same tool names and ANNAS_* variables. Verify the release archive before
  # extracting the binary; downloads live on NFS HDD.
  mcp_annas_version = "0.8.2"
  mcp_annas_sha256 = {
    amd64 = "66a06de94026eeca63f1e9979451758f54acbfa91a0fa89027c59d1bc03fafe7"
    arm64 = "a422b8d21911706b2c8084c9da7adeb2ea55230a0820240c6bbac8353922a301"
  }
  # cyanheads/pubmed-mcp-server 2.12.2: NCBI E-utilities PubMed/PMC server,
  # native streamable HTTP (multi-arch index digest). Read-only, keyless.
  mcp_pubmed_image = "ghcr.io/cyanheads/pubmed-mcp-server:2.12.2@sha256:18a156d2c0f6fa16332943dfb3fe89a09ba64cdd5757530d4015187d914a7721"
  # cyanheads/openfda-mcp-server 0.10.0: openFDA drug/device/food/tobacco
  # server, native streamable HTTP (multi-arch index digest). Read-only, keyless.
  mcp_openfda_image = "ghcr.io/cyanheads/openfda-mcp-server:0.10.0@sha256:6bade603ec477979f10c2d73289276c30dfd7958a84bbb29a232ab778970577a"
  # cyanheads/openalex-mcp-server 0.11.1: OpenAlex scholarly-works server,
  # native streamable HTTP (multi-arch index digest). Read-only; account key
  # (openalex.api_key) for the larger daily budget.
  mcp_openalex_image = "ghcr.io/cyanheads/openalex-mcp-server:0.11.1@sha256:7404b67e2203607ecb616b75f805d25f037b58f01859ca50b5f6281a4b23a780"
  # sourabhmadur/ticketmaster-mcp (commit bc3367d, tarball sha256 4825ec19...):
  # Ticketmaster Discovery API v2 events/attractions/venues, stdio only, so it
  # runs behind the same mcp-proxy bridge as comfy-mcp. Dependencies are pinned
  # explicitly (its own pins are open ranges); the base image by index digest.
  mcp_ticketmaster_image   = "docker.io/python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90"
  mcp_ticketmaster_package = "https://github.com/sourabhmadur/ticketmaster-mcp/archive/bc3367d251e5d1877f7222d23826a2bbe2be383e.tar.gz#sha256=4825ec19ecd764b6c76e1a977fe875c62fe0f27741c912129ae80881e0a99603"
  mcp_ticketmaster_deps    = "mcp==1.30.0 httpx==0.28.1 python-dotenv==1.2.4"
  # Official Comfy-Org comfy-mcp is stdio-only and needs mcp>=2; mcp-proxy
  # (mcp<2) bridges it to streamable HTTP, so each gets its own venv.
  mcp_comfyui_image    = "docker.io/python:3.13-slim"
  mcp_comfyui_packages = "comfy-mcp==0.10.0 comfy-cli==1.22.0"
  mcp_proxy_package    = "mcp-proxy==0.13.0"
  mcp_espn_host        = "espn-mcp.home.shdr.ch"
}

resource "kubernetes_secret_v1" "mcp" {
  for_each = toset(nonsensitive(keys(local.mcp_secrets)))

  metadata {
    name      = each.key
    namespace = local.mcp_namespace
  }

  data = local.mcp_secrets[each.key]
  type = "Opaque"
}

# espn and finviz are built in GitLab.
resource "kubernetes_secret_v1" "mcp_gitlab_registry" {
  metadata {
    name      = "gitlab-registry"
    namespace = local.mcp_namespace
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

# espn alone is also reached at its own hostname, with no sign-in, for testing
# the server while it is being developed.
resource "kubernetes_manifest" "mcp_espn_route" {
  depends_on = [kubernetes_manifest.main_gateway]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "espn"
      namespace = local.mcp_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.mcp_espn_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.mcp["espn"].metadata[0].name
          port = local.mcp_port["espn"]
        }]
      }]
    }
  }
}

resource "kubernetes_service_v1" "mcp" {
  for_each = local.mcp_port

  metadata {
    name      = each.key
    namespace = local.mcp_namespace
    labels    = { app = each.key }
  }

  spec {
    selector = { app = each.key }
    port {
      name        = "mcp"
      port        = each.value
      target_port = each.value
    }
  }
}

# Only the gateways reach a server. Health probes come from the node, which
# Cilium admits without a rule.
resource "kubernetes_manifest" "mcp_cilium_network" {
  depends_on = [kubernetes_manifest.cilium_cluster_baseline_network]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "mcp-ingress"
      namespace = local.mcp_namespace
    }
    spec = {
      endpointSelector = {}
      ingress = [
        {
          fromEndpoints = [{ matchLabels = { "io.kubernetes.pod.namespace" = local.meridian_namespace, "app.kubernetes.io/name" = "meridian" } }]
          toPorts = [{
            ports = [for port in distinct(values(local.mcp_port)) : { port = tostring(port), protocol = "TCP" }]
          }]
        },
        {
          fromEndpoints = [{ matchLabels = { "io.kubernetes.pod.namespace" = local.litellm_ns, "app" = "litellm" } }]
          toPorts = [{
            ports = [for server, port in local.mcp_port : { port = tostring(port), protocol = "TCP" } if contains(local.mcp_litellm_routes, server)]
          }]
        },
      ]
    }
  }
}

# The gateway that serves espn's test hostname reaches espn alone.
resource "kubernetes_manifest" "mcp_espn_cilium_network" {
  depends_on = [kubernetes_manifest.cilium_cluster_baseline_network]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "espn-test-hostname"
      namespace = local.mcp_namespace
    }
    spec = {
      endpointSelector = { matchLabels = { app = "espn" } }
      ingress = [{
        fromEntities = ["ingress"]
        toPorts = [{
          ports = [{ port = tostring(local.mcp_port["espn"]), protocol = "TCP" }]
        }]
      }]
    }
  }
}

# The annas server writes what it downloads to the folder LiteLLM's pod used
# (claim annas-downloads in the litellm namespace, which still owns the
# folder). A claim cannot be shared across namespaces, so this is a second,
# static volume over that volume's own NFS subdirectory, as for the `orion`
# agent's read-only copy (litellm.tf).
resource "kubernetes_persistent_volume_v1" "mcp_annas_downloads" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "mcp-annas-downloads"
  }

  spec {
    capacity = { storage = "50Gi" }

    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "mcp-annas-downloads"
        volume_attributes = {
          server = var.nfs_server_ip
          share  = "/mnt/hdd/data/${kubernetes_persistent_volume_claim_v1.litellm_annas_downloads.spec[0].volume_name}"
        }
      }
    }

    mount_options = ["nfsvers=4.1", "hard", "nointr"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "mcp_annas_downloads" {
  metadata {
    name      = "annas-downloads"
    namespace = local.mcp_namespace
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.mcp_annas_downloads.metadata[0].name

    resources {
      requests = { storage = "50Gi" }
    }
  }
}

resource "kubernetes_deployment_v1" "mcp_finviz" {
  metadata {
    name      = "finviz"
    namespace = local.mcp_namespace
    labels    = { app = "finviz" }
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "finviz" }
    }

    template {
      metadata {
        labels = { app = "finviz" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["finviz"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        image_pull_secrets {
          name = kubernetes_secret_v1.mcp_gitlab_registry.metadata[0].name
        }

        container {
          name              = "finviz"
          image             = local.mcp_finviz_image
          image_pull_policy = "Always"

          port {
            container_port = local.mcp_port["finviz"]
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
            value = tostring(local.mcp_port["finviz"])
          }

          env {
            name = "FINVIZ_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mcp["finviz"].metadata[0].name
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
      # Keel rewrites these when :latest moves.
      metadata[0].annotations["kubernetes.io/change-cause"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_time" {
  metadata {
    name      = "time"
    namespace = local.mcp_namespace
    labels    = { app = "time" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "time" }
    }

    template {
      metadata {
        labels = { app = "time" }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "time"
          image = local.mcp_time_image
          args  = ["--transport", "stream", "--address", "http://0.0.0.0:${local.mcp_port["time"]}/mcp"]

          port {
            container_port = local.mcp_port["time"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_google_maps" {
  count = local.mcp_google_maps ? 1 : 0

  metadata {
    name      = "google-maps"
    namespace = local.mcp_namespace
    labels    = { app = "google-maps" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "google-maps" }
    }

    template {
      metadata {
        labels = { app = "google-maps" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["google-maps"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name    = "google-maps"
          image   = local.mcp_google_maps_image
          command = ["npx", "-y", local.mcp_google_maps_package, "--host", "0.0.0.0", "--port", tostring(local.mcp_port["google-maps"])]

          port {
            container_port = local.mcp_port["google-maps"]
            name           = "google-maps"
          }

          env {
            name = "GOOGLE_MAPS_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mcp["google-maps"].metadata[0].name
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
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_espn" {
  metadata {
    name      = "espn"
    namespace = local.mcp_namespace
    labels    = { app = "espn" }
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "espn" }
    }

    template {
      metadata {
        labels = { app = "espn" }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        image_pull_secrets {
          name = kubernetes_secret_v1.mcp_gitlab_registry.metadata[0].name
        }

        container {
          name              = "espn"
          image             = local.mcp_espn_image
          command           = ["espn-mcp", "--http", "8080"]
          image_pull_policy = "Always"

          port {
            name           = "espn-mcp"
            container_port = local.mcp_port["espn"]
            protocol       = "TCP"
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.mcp_port["espn"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.mcp_port["espn"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
      # Keel rewrites these when :latest moves.
      metadata[0].annotations["kubernetes.io/change-cause"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_tmdb" {
  metadata {
    name      = "tmdb"
    namespace = local.mcp_namespace
    labels    = { app = "tmdb" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "tmdb" }
    }

    template {
      metadata {
        labels = { app = "tmdb" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["tmdb"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "tmdb"
          image = local.mcp_tmdb_image
          # Native Streamable HTTP; auth is TMDB v4 Read Access Token (Bearer).

          port {
            container_port = local.mcp_port["tmdb"]
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
            value = tostring(local.mcp_port["tmdb"])
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
                name = kubernetes_secret_v1.mcp["tmdb"].metadata[0].name
                key  = "TMDB_API_KEY"
              }
            }
          }


          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.mcp_port["tmdb"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 12
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.mcp_port["tmdb"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_pubmed" {
  metadata {
    name      = "pubmed"
    namespace = local.mcp_namespace
    labels    = { app = "pubmed" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "pubmed" }
    }

    template {
      metadata {
        labels = { app = "pubmed" }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "pubmed"
          image = local.mcp_pubmed_image
          # Native Streamable HTTP, stateless, no sign-in. Keyless NCBI E-utilities (3 req/s, paced by
          # the server's own request queue); no secrets. Unpaywall stays off
          # because UNPAYWALL_EMAIL is unset.

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
            value = tostring(local.mcp_port["pubmed"])
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

          # Probed from inside the container.
          readiness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.mcp_port["pubmed"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.mcp_port["pubmed"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_openfda" {
  metadata {
    name      = "openfda"
    namespace = local.mcp_namespace
    labels    = { app = "openfda" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "openfda" }
    }

    template {
      metadata {
        labels = { app = "openfda" }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "openfda"
          image = local.mcp_openfda_image
          # Native Streamable HTTP, stateless, no sign-in. Keyless openFDA (1K requests/day per IP;
          # OPENFDA_API_KEY unset); no secrets. DataCanvas staging is off, but
          # the server still lists the openfda_dataframe_* tools (they answer
          # canvas_disabled), so the gateway allowlists the 12 real tools.

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
            value = tostring(local.mcp_port["openfda"])
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

          # Probed from inside the container.
          readiness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.mcp_port["openfda"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.mcp_port["openfda"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_openalex" {
  metadata {
    name      = "openalex"
    namespace = local.mcp_namespace
    labels    = { app = "openalex" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "openalex" }
    }

    template {
      metadata {
        labels = { app = "openalex" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["openalex"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "openalex"
          image = local.mcp_openalex_image
          # Native Streamable HTTP, stateless, no sign-in. OPENALEX_API_KEY is Shedrach's free OpenAlex
          # account key (sops openalex.api_key: $1/day budget, 10K credits on
          # 2026-11-15, against the anonymous tier); OPENALEX_MAILTO unset.

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
            value = tostring(local.mcp_port["openalex"])
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
                name = kubernetes_secret_v1.mcp["openalex"].metadata[0].name
                key  = "OPENALEX_API_KEY"
              }
            }
          }

          # Probed from inside the container.
          readiness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.mcp_port["openalex"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["bun", "-e", "fetch('http://127.0.0.1:${local.mcp_port["openalex"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_ticketmaster" {
  metadata {
    name      = "ticketmaster"
    namespace = local.mcp_namespace
    labels    = { app = "ticketmaster" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "ticketmaster" }
    }

    template {
      metadata {
        labels = { app = "ticketmaster" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["ticketmaster"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "ticketmaster"
          image = local.mcp_ticketmaster_image
          # No sign-in. The server is stdio-only; mcp-proxy serves it as streamable
          # HTTP (one stdio child per session). Read-only Discovery API v2 (6
          # tools, no purchase flow). The consumer key reaches the child as
          # TICKETMASTER_API_KEY via --pass-environment and is never a tool
          # argument. It travels in the Discovery request query string, so the
          # child's httpx request logger is raised to WARNING to keep the key
          # out of container logs.
          command = ["sh", "-c", <<-EOT
            set -e
            python -m venv /opt/tm && /opt/tm/bin/pip install --no-cache-dir --quiet ${local.mcp_ticketmaster_deps} "${local.mcp_ticketmaster_package}"
            python -m venv /opt/proxy && /opt/proxy/bin/pip install --no-cache-dir --quiet ${local.mcp_proxy_package}
            exec /opt/proxy/bin/mcp-proxy --host 0.0.0.0 --port ${local.mcp_port["ticketmaster"]} --pass-environment -- /opt/tm/bin/python -c 'import logging; logging.getLogger("httpx").setLevel(logging.WARNING); from ticketmaster_mcp.server import main; main()'
          EOT
          ]

          env {
            name = "TICKETMASTER_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mcp["ticketmaster"].metadata[0].name
                key  = "TICKETMASTER_API_KEY"
              }
            }
          }

          # Probed from inside the container.
          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["ticketmaster"]}/status', timeout=4)"]
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 18
          }

          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["ticketmaster"]}/status', timeout=4)"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = local.mcp_namespace
    labels    = { app = "jellyfin" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "jellyfin" }
    }

    template {
      metadata {
        labels = { app = "jellyfin" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["jellyfin"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "jellyfin"
          image = local.mcp_jellyfin_image
          # Native Streamable HTTP; auth is a dedicated Jellyfin API key.
          # Condensed mode: 3 action-routed tools instead of 368 1:1 API tools.

          port {
            container_port = local.mcp_port["jellyfin"]
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
            value = tostring(local.mcp_port["jellyfin"])
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
                name = kubernetes_secret_v1.mcp["jellyfin"].metadata[0].name
                key  = "JELLYFIN_API_KEY"
              }
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.mcp_port["jellyfin"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 12
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.mcp_port["jellyfin"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_homeassistant" {
  metadata {
    name      = "homeassistant"
    namespace = local.mcp_namespace
    labels    = { app = "homeassistant" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "homeassistant" }
    }

    template {
      metadata {
        labels = { app = "homeassistant" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["homeassistant"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "homeassistant"
          image = local.mcp_homeassistant_image
          # Standard-mode HTTP has no sign-in beyond the URL path. Home
          # Assistant's API goes through the home
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
                name = kubernetes_secret_v1.mcp["homeassistant"].metadata[0].name
                key  = "HOMEASSISTANT_TOKEN"
              }
            }
          }

          env {
            name  = "MCP_HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "MCP_PORT"
            value = tostring(local.mcp_port["homeassistant"])
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

          # Probed from inside the container.
          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["homeassistant"]}/healthz', timeout=5)"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 6
            failure_threshold     = 12
          }

          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["homeassistant"]}/healthz', timeout=5)"]
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
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_karakeep" {
  metadata {
    name      = "karakeep"
    namespace = local.mcp_namespace
    labels    = { app = "karakeep" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "karakeep" }
    }

    template {
      metadata {
        labels = { app = "karakeep" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["karakeep"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "karakeep"
          image = local.mcp_karakeep_image
          # supergateway has no sign-in here, and the API key acts as
          # Shedrach's Karakeep account.
          command = ["sh", "-c", <<-EOT
            set -e
            npm install -g --no-fund --no-audit --loglevel=error ${local.mcp_karakeep_packages}
            exec supergateway --stdio karakeep-mcp --outputTransport streamableHttp --host 0.0.0.0 --port ${local.mcp_port["karakeep"]} --healthEndpoint /healthz
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
                name = kubernetes_secret_v1.mcp["karakeep"].metadata[0].name
                key  = "KARAKEEP_API_KEY"
              }
            }
          }

          # Probed from inside the container.
          readiness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.mcp_port["karakeep"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 18
          }

          liveness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.mcp_port["karakeep"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = local.mcp_namespace
    labels    = { app = "nextcloud" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "nextcloud" }
    }

    template {
      metadata {
        labels = { app = "nextcloud" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["nextcloud"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "nextcloud"
          image = local.mcp_nextcloud_image
          # No sign-in here. Signs in to
          # Nextcloud as Shedrach's account with a dedicated app password
          # (nextcloud.tf), so it reaches everything he can. Only the Files,
          # Sharing, Calendar and Contacts tools register; semantic search
          # stays off (the default).
          command = [
            "/opt/venv/bin/nextcloud-mcp-server", "run",
            "--host", "0.0.0.0",
            "--port", tostring(local.mcp_port["nextcloud"]),
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
                name = kubernetes_secret_v1.mcp["nextcloud"].metadata[0].name
                key  = "NEXTCLOUD_MCP_PASSWORD"
              }
            }
          }

          # Probed from inside the container.
          # Neither endpoint calls Nextcloud, so its outages do not restart
          # this container.
          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["nextcloud"]}/health/ready', timeout=4)"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 18
          }

          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["nextcloud"]}/health/live', timeout=4)"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_yourspotify" {
  metadata {
    name      = "yourspotify"
    namespace = local.mcp_namespace
    labels    = { app = "yourspotify" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "yourspotify" }
    }

    template {
      metadata {
        labels = { app = "yourspotify" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["yourspotify"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "yourspotify"
          image = local.mcp_karakeep_image
          # supergateway has no sign-in here. YOUR_SPOTIFY_TOKEN is
          # Your Spotify's public (share) token: it reads Shedrach's stats and
          # is sent as ?token=, so the server logs no requests. No Spotify Web
          # API credentials, so the playback/playlist tools never register.
          command = ["sh", "-c", <<-EOT
            set -e
            cd /tmp
            node -e "fetch('${local.mcp_yourspotify_source}').then(r => { if (!r.ok) throw new Error(r.status); return r.arrayBuffer(); }).then(b => require('fs').writeFileSync('src.tgz', Buffer.from(b)))"
            echo "${local.mcp_yourspotify_sha256}  src.tgz" | sha256sum -c -
            rm -rf app && mkdir app && tar xzf src.tgz -C app --strip-components=1
            cd app
            npm ci --no-fund --no-audit --loglevel=error
            npm run build --silent
            npm install -g --no-fund --no-audit --loglevel=error supergateway@4.2.1
            exec supergateway --stdio "node /tmp/app/build/index.js" --outputTransport streamableHttp --host 0.0.0.0 --port ${local.mcp_port["yourspotify"]} --healthEndpoint /healthz
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
                name = kubernetes_secret_v1.mcp["yourspotify"].metadata[0].name
                key  = "YOUR_SPOTIFY_TOKEN"
              }
            }
          }

          # Probed from inside the container.
          readiness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.mcp_port["yourspotify"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30
          }

          liveness_probe {
            exec {
              command = ["node", "-e", "fetch('http://127.0.0.1:${local.mcp_port["yourspotify"]}/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_annas" {
  metadata {
    name      = "annas"
    namespace = local.mcp_namespace
    labels    = { app = "annas" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "annas" }
    }

    template {
      metadata {
        labels = { app = "annas" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["annas"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "annas"
          image = local.mcp_ticketmaster_image
          # Bridged by mcp-proxy, like Ticketmaster. Pin the mirror: automatic
          # discovery sends membership requests to third-party-selected hosts.
          command = ["sh", "-c", <<-EOT
            set -e
            python - <<'PY'
            import hashlib, io, os, platform, tarfile, urllib.request
            arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
            expected = ${jsonencode(local.mcp_annas_sha256)}
            name = "annas-mcp_${local.mcp_annas_version}_linux_" + arch
            url = "https://github.com/SokolskyNikita/annas-mcp/releases/download/v${local.mcp_annas_version}/" + name + ".tar.xz"
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != expected[arch]:
                raise RuntimeError("Anna's MCP release checksum mismatch")
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as archive:
                with archive.extractfile(name + "/annas-mcp") as source, open("/opt/annas-mcp", "wb") as target:
                    target.write(source.read())
            os.chmod("/opt/annas-mcp", 0o755)
            PY
            python -m venv /opt/proxy && /opt/proxy/bin/pip install --no-cache-dir --quiet ${local.mcp_proxy_package}
            exec /opt/proxy/bin/mcp-proxy --host 0.0.0.0 --port ${local.mcp_port["annas"]} --pass-environment -- /opt/annas-mcp mcp
          EOT
          ]

          env {
            name  = "ANNAS_BASE_URL"
            value = "annas-archive.gl"
          }
          # Only the mirror above gets the membership key: no automatic pick.
          env {
            name  = "ANNAS_AUTO_BASE_URL"
            value = "false"
          }
          env {
            name  = "ANNAS_DOWNLOAD_PATH"
            value = "/downloads"
          }
          env {
            name = "ANNAS_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mcp["annas"].metadata[0].name
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
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["annas"]}/status', timeout=4)"]
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30
          }
          liveness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${local.mcp_port["annas"]}/status', timeout=4)"]
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

        volume {
          name = "annas-downloads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.mcp_annas_downloads.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = local.mcp_namespace
    labels    = { app = "qbittorrent" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "qbittorrent" }
    }

    template {
      metadata {
        labels = { app = "qbittorrent" }
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.mcp["qbittorrent"].data)))
        }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "qbittorrent"
          image = local.mcp_qbittorrent_image
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
            container_port = local.mcp_port["qbittorrent"]
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
                name = kubernetes_secret_v1.mcp["qbittorrent"].metadata[0].name
                key  = "QBIT_MCP_USERNAME"
              }
            }
          }

          env {
            name = "QBITTORRENT_QBITTORRENT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mcp["qbittorrent"].metadata[0].name
                key  = "QBIT_MCP_PASSWORD"
              }
            }
          }

          env {
            name = "QBITTORRENT_HTTP_AUTH_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mcp["qbittorrent"].metadata[0].name
                key  = "QBIT_MCP_HTTP_TOKEN"
              }
            }
          }

          # No health endpoint and /sse needs the token: probe the socket.
          readiness_probe {
            tcp_socket {
              port = local.mcp_port["qbittorrent"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 6
          }

          liveness_probe {
            tcp_socket {
              port = local.mcp_port["qbittorrent"]
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_deployment_v1" "mcp_comfyui" {
  metadata {
    name      = "comfyui"
    namespace = local.mcp_namespace
    labels    = { app = "comfyui" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "comfyui" }
    }

    template {
      metadata {
        labels = { app = "comfyui" }
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        container {
          name  = "comfyui"
          image = local.mcp_comfyui_image
          # The tools submit arbitrary ComfyUI workflows.
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
            python -m venv /opt/comfy && /opt/comfy/bin/pip install --no-cache-dir --quiet ${local.mcp_comfyui_packages}
            python -m venv /opt/proxy && /opt/proxy/bin/pip install --no-cache-dir --quiet ${local.mcp_proxy_package}
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
            exec /opt/proxy/bin/mcp-proxy --host 0.0.0.0 --port ${local.mcp_port["comfyui"]} --pass-environment -- /opt/comfy/bin/comfy-mcp
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
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno sets priorityClassName from the namespace's tier.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}
