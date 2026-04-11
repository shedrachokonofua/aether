# =============================================================================
# Tuliprox — IPTV Proxy
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# Config files are rendered from secrets (provider credentials, proxy auth).

resource "random_password" "tuliprox_rewrite_secret" {
  length  = 32
  special = false
  upper   = false
  # Produces a 32-char lowercase hex-compatible string
  override_special = ""
}

locals {
  tuliprox_image          = "ghcr.io/euzu/tuliprox:latest"
  tuliprox_host           = "tuliprox.apps.home.shdr.ch"
  tuliprox_port           = 8901
  tuliprox_labels         = { app = "tuliprox" }
  tuliprox_rewrite_secret = md5(random_password.tuliprox_rewrite_secret.result)
}

# =============================================================================
# PVC — Runtime Data
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "tuliprox_data" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "tuliprox-data"
    namespace = local.jellyfin_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }
}

# =============================================================================
# Config — rendered from secrets
# =============================================================================

resource "kubernetes_secret_v1" "tuliprox_config" {
  depends_on = [kubernetes_namespace_v1.media]

  metadata {
    name      = "tuliprox-config"
    namespace = local.jellyfin_ns
  }

  data = {
    "config.yml" = <<-EOT
      api:
        host: 0.0.0.0
        port: ${local.tuliprox_port}
        web_root: /app/web
      working_dir: /app/data
      update_on_boot: true
      proxy:
        url: socks5://${var.rotating_proxy_addr}
      reverse_proxy:
        rewrite_secret: ${local.tuliprox_rewrite_secret}
        stream:
          retry: true
          buffer:
            enabled: true
            size: 1024
      web_ui:
        enabled: true
    EOT

    "source.yml" = <<-EOT
      templates:
        - name: ALL_CHAN
          value: 'Group ~ ".*"'

      inputs:
        - name: "${var.secrets["tuliprox.providers.0.accounts.0.username"]}"
          type: xtream
          url: "${var.secrets["tuliprox.providers.0.url"]}"
          username: "${var.secrets["tuliprox.providers.0.accounts.0.username"]}"
          password: "${var.secrets["tuliprox.providers.0.accounts.0.password"]}"
          max_connections: ${var.secrets["tuliprox.providers.0.accounts.0.max_connections"]}
          options:
            xtream_skip_vod: true
            xtream_skip_series: true
          epg:
            sources:
              - url: "${var.secrets["tuliprox.providers.0.url"]}/xmltv.php?username=${var.secrets["tuliprox.providers.0.accounts.0.username"]}&password=${var.secrets["tuliprox.providers.0.accounts.0.password"]}"
          aliases:
            - name: "${var.secrets["tuliprox.providers.0.accounts.1.username"]}"
              url: "${var.secrets["tuliprox.providers.0.url"]}"
              username: "${var.secrets["tuliprox.providers.0.accounts.1.username"]}"
              password: "${var.secrets["tuliprox.providers.0.accounts.1.password"]}"
              max_connections: ${var.secrets["tuliprox.providers.0.accounts.1.max_connections"]}
            - name: "${var.secrets["tuliprox.providers.0.accounts.2.username"]}"
              url: "${var.secrets["tuliprox.providers.0.url"]}"
              username: "${var.secrets["tuliprox.providers.0.accounts.2.username"]}"
              password: "${var.secrets["tuliprox.providers.0.accounts.2.password"]}"
              max_connections: ${var.secrets["tuliprox.providers.0.accounts.2.max_connections"]}
        - name: "${var.secrets["tuliprox.providers.1.accounts.0.username"]}"
          type: xtream
          url: "${var.secrets["tuliprox.providers.1.url"]}"
          username: "${var.secrets["tuliprox.providers.1.accounts.0.username"]}"
          password: "${var.secrets["tuliprox.providers.1.accounts.0.password"]}"
          max_connections: ${var.secrets["tuliprox.providers.1.accounts.0.max_connections"]}
          options:
            xtream_skip_vod: true
            xtream_skip_series: true
          epg:
            sources:
              - url: "${var.secrets["tuliprox.providers.1.url"]}/xmltv.php?username=${var.secrets["tuliprox.providers.1.accounts.0.username"]}&password=${var.secrets["tuliprox.providers.1.accounts.0.password"]}"
          aliases:
            - name: "${var.secrets["tuliprox.providers.1.accounts.1.username"]}"
              url: "${var.secrets["tuliprox.providers.1.url"]}"
              username: "${var.secrets["tuliprox.providers.1.accounts.1.username"]}"
              password: "${var.secrets["tuliprox.providers.1.accounts.1.password"]}"
              max_connections: ${var.secrets["tuliprox.providers.1.accounts.1.max_connections"]}
            - name: "${var.secrets["tuliprox.providers.1.accounts.2.username"]}"
              url: "${var.secrets["tuliprox.providers.1.url"]}"
              username: "${var.secrets["tuliprox.providers.1.accounts.2.username"]}"
              password: "${var.secrets["tuliprox.providers.1.accounts.2.password"]}"
              max_connections: ${var.secrets["tuliprox.providers.1.accounts.2.max_connections"]}

      sources:
        - inputs:
            - "${var.secrets["tuliprox.providers.0.accounts.0.username"]}"
            - "${var.secrets["tuliprox.providers.1.accounts.0.username"]}"
          targets:
            - name: all_channels
              use_memory_cache: true
              output:
                - type: xtream
                - type: m3u
                  filename: playlist.m3u
              filter: "!ALL_CHAN!"
    EOT

    "api-proxy.yml" = <<-EOT
      server:
        - name: default
          protocol: https
          host: tuliprox.home.shdr.ch
          port: 443
          timezone: America/Toronto
          message: Welcome
      user:
        - target: all_channels
          credentials:
            - username: ${var.secrets["tuliprox.proxy_username"]}
              password: ${var.secrets["tuliprox.proxy_password"]}
              proxy: reverse
              server: default
    EOT

    "mapping.yml" = <<-EOT
      mappings:
        mapping: []
    EOT
  }

  type = "Opaque"
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "tuliprox" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.tuliprox_data,
    kubernetes_secret_v1.tuliprox_config,
  ]

  metadata {
    name      = "tuliprox"
    namespace = local.jellyfin_ns
    labels    = local.tuliprox_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.tuliprox_labels
    }

    template {
      metadata {
        labels = local.tuliprox_labels
      }

      spec {
        init_container {
          name  = "copy-config"
          image = "busybox:latest"
          command = ["sh", "-c", "cp /secret-config/* /app/config/"]

          volume_mount {
            name       = "secret-config"
            mount_path = "/secret-config"
            read_only  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/app/config"
          }
        }

        container {
          name  = "tuliprox"
          image = local.tuliprox_image

          port {
            container_port = local.tuliprox_port
            name           = "http"
          }

          volume_mount {
            name       = "config"
            mount_path = "/app/config"
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.tuliprox_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = local.tuliprox_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "secret-config"
          secret {
            secret_name = kubernetes_secret_v1.tuliprox_config.metadata[0].name
          }
        }

        volume {
          name = "config"
          empty_dir {}
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.tuliprox_data.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "tuliprox" {
  metadata {
    name      = "tuliprox"
    namespace = local.jellyfin_ns
    labels    = local.tuliprox_labels
  }

  spec {
    selector = local.tuliprox_labels

    port {
      port        = local.tuliprox_port
      target_port = local.tuliprox_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "tuliprox_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.tuliprox]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "tuliprox"
      namespace = local.jellyfin_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.tuliprox_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.tuliprox.metadata[0].name
          port = local.tuliprox_port
        }]
      }]
    }
  }
}
