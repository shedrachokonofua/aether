# =============================================================================
# SearXNG - Private Metasearch
# =============================================================================
# Migrated from the legacy Podman VM to Kubernetes.

locals {
  searxng_image  = "docker.io/searxng/searxng:latest"
  searxng_host   = "searxng.home.shdr.ch"
  searxng_port   = 8080
  searxng_ns     = kubernetes_namespace_v1.infra.metadata[0].name
  searxng_labels = { app = "searxng" }
}

# =============================================================================
# Config
# =============================================================================

resource "kubernetes_secret_v1" "searxng_settings" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "searxng-settings"
    namespace = local.searxng_ns
  }

  data = {
    "settings.yml" = <<-EOT
      use_default_settings: true

      general:
        debug: false
        instance_name: "Aether Search"
        enable_metrics: true
        open_metrics: ""

      search:
        safe_search: 0
        autocomplete: "startpage"
        autocomplete_min: 3
        favicon_resolver: "duckduckgo"
        default_lang: "en"
        formats:
          - html
          - json

      server:
        port: ${local.searxng_port}
        bind_address: "0.0.0.0"
        base_url: https://searxng.home.shdr.ch/
        limiter: false
        public_instance: false
        secret_key: "${var.secrets["searxng.secret_key"]}"
        image_proxy: false
        method: "POST"
        default_http_headers:
          X-Content-Type-Options: nosniff
          X-Download-Options: noopen
          X-Robots-Tag: noindex, nofollow
          Referrer-Policy: no-referrer

      valkey:
        url: false

      ui:
        default_theme: simple
        center_alignment: false
        query_in_title: true
        infinite_scroll: false
        results_on_new_tab: false
        theme_args:
          simple_style: light

      outgoing:
        request_timeout: 1.0
        pool_connections: 100
        pool_maxsize: 20
        enable_http2: true

      plugins:
        searx.plugins.calculator.SXNGPlugin:
          active: true
        searx.plugins.hash_plugin.SXNGPlugin:
          active: true
        searx.plugins.self_info.SXNGPlugin:
          active: true
        searx.plugins.unit_converter.SXNGPlugin:
          active: true
        searx.plugins.ahmia_filter.SXNGPlugin:
          active: true
        searx.plugins.hostnames.SXNGPlugin:
          active: true
        searx.plugins.time_zone.SXNGPlugin:
          active: true
        searx.plugins.tracker_url_remover.SXNGPlugin:
          active: true

      categories_as_tabs:
        general:
        images:
        videos:
        news:
        map:
        music:
        it:
        science:
        files:
        social media:

      engines:
        - name: kagi
          engine: json_engine
          shortcut: kag
          categories: general
          paging: true
          search_url: https://kagi.com/api/v0/search?q={query}
          headers:
            Authorization: "Bot ${var.secrets["searxng.kagi_api_key"]}"
          results_query: data
          url_query: url
          title_query: title
          content_query: snippet
          timeout: 5
          disabled: false
          about:
            website: https://www.kagi.com/
            official_api_documentation: https://help.kagi.com/kagi/api/search.html
            use_official_api: true
            require_api_key: true
            results: JSON
    EOT
  }

  type = "Opaque"
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "searxng" {
  depends_on = [kubernetes_secret_v1.searxng_settings]

  metadata {
    name      = "searxng"
    namespace = local.searxng_ns
    labels    = local.searxng_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.searxng_labels
    }

    template {
      metadata {
        labels = local.searxng_labels
      }

      spec {
        enable_service_links = false

        container {
          name  = "searxng"
          image = local.searxng_image

          port {
            container_port = local.searxng_port
            name           = "http"
          }

          volume_mount {
            name       = "settings"
            mount_path = "/etc/searxng/settings.yml"
            sub_path   = "settings.yml"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.searxng_port
            }
            initial_delay_seconds = 20
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.searxng_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "settings"
          secret {
            secret_name = kubernetes_secret_v1.searxng_settings.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "searxng" {
  metadata {
    name      = "searxng"
    namespace = local.searxng_ns
    labels    = local.searxng_labels
  }

  spec {
    selector = local.searxng_labels

    port {
      port        = local.searxng_port
      target_port = local.searxng_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute - Gateway API
# =============================================================================

resource "kubernetes_manifest" "searxng_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.searxng]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "searxng"
      namespace = local.searxng_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.searxng_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.searxng.metadata[0].name
          port = local.searxng_port
        }]
      }]
    }
  }
}
