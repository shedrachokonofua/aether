# =============================================================================
# Jellyfin — Media Server
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# GPU transcoding via talos-neo (RTX Pro 6000).
# Includes rclone sidecar for nzbdav WebDAV mount.

locals {
  jellyfin_image = "docker.io/jellyfin/jellyfin:latest"
  # Gateway API matches the Host header from Caddy (header_up Host …); public URL is tv.shdr.ch.
  jellyfin_host           = "jellyfin.home.shdr.ch"
  jellyfin_public_url     = "https://tv.shdr.ch"
  jellyfin_port           = 8096
  media_ns                = module.namespace["media"].name
  jellyfin_ns             = module.namespace["jellyfin"].name
  jellyfin_labels         = { app = "jellyfin" }
  jellyfin_exporter_image = "docker.io/rebelcore/jellyfin-exporter:v1.5.2"
  jellyfin_exporter_port  = 9594

  rclone_image = "rclone/rclone:latest"
}

# =============================================================================
# Namespace
# =============================================================================


# =============================================================================
# PVCs
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "jellyfin_config" {
  depends_on = [module.namespace["jellyfin"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "jellyfin-config"
    namespace = local.jellyfin_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "10Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "jellyfin_cache" {
  depends_on = [module.namespace["jellyfin"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "jellyfin-cache"
    namespace = local.jellyfin_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "20Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_v1" "media_hdd" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "media-hdd"
  }

  spec {
    capacity = { storage = "1Ti" }

    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "media-hdd"
        read_only     = false
        volume_attributes = {
          server = var.nfs_server_ip
          share  = "/mnt/hdd/data"
        }
      }
    }

    mount_options = ["nfsvers=4.1", "hard", "nointr"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "media_hdd" {
  depends_on = [module.namespace["media"], kubernetes_persistent_volume_v1.media_hdd]

  metadata {
    name      = "media-hdd"
    namespace = local.media_ns
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.media_hdd.metadata[0].name

    resources {
      requests = { storage = "1Ti" }
    }
  }
}

resource "kubernetes_persistent_volume_v1" "jellyfin_media_hdd" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "jellyfin-media-hdd"
  }

  spec {
    capacity = { storage = "1Ti" }

    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "jellyfin-media-hdd"
        read_only     = false
        volume_attributes = {
          server = var.nfs_server_ip
          share  = "/mnt/hdd/data"
        }
      }
    }

    mount_options = ["nfsvers=4.1", "hard", "nointr"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "jellyfin_media_hdd" {
  depends_on = [module.namespace["jellyfin"], kubernetes_persistent_volume_v1.jellyfin_media_hdd]

  metadata {
    name      = "media-hdd"
    namespace = local.jellyfin_ns
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.jellyfin_media_hdd.metadata[0].name

    resources {
      requests = { storage = "1Ti" }
    }
  }
}

# =============================================================================
# Exporter Secret
# =============================================================================

resource "kubernetes_secret_v1" "jellyfin_exporter" {
  depends_on = [module.namespace["jellyfin"]]

  metadata {
    name      = "jellyfin-exporter"
    namespace = local.jellyfin_ns
    labels    = local.jellyfin_labels
  }

  data = {
    token = var.secrets["jellyfin.exporter_api_key"]
  }
}

# =============================================================================
# =============================================================================
# Logging ConfigMap — overrides PVC /config/config/logging.json
# Quiets IPTV/chapter spam that was destroying stdout retention; keeps
# BaseItem WRN ("Unable to find linked item") at Warning so the strm-link-rot
# alert rule still fires. Uses subPath overlay so the rest of /config stays PVC-owned.
# =============================================================================

locals {
  jellyfin_logging_config = jsonencode({
    Serilog = {
      MinimumLevel = {
        Default = "Information"
        Override = {
          Microsoft                              = "Warning"
          System                                 = "Warning"
          "Jellyfin.LiveTv"                      = "Warning"
          "Emby.Server.Implementations.Chapters" = "Warning"
        }
      }
      WriteTo = [
        {
          Name = "Console"
          Args = {
            outputTemplate = "[{Timestamp:HH:mm:ss}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message:lj}{NewLine}{Exception}"
          }
        },
        {
          Name = "Async"
          Args = {
            configure = [
              {
                Name = "File"
                Args = {
                  path                   = "%JELLYFIN_LOG_DIR%//log_.log"
                  rollingInterval        = "Day"
                  retainedFileCountLimit = 7
                  rollOnFileSizeLimit    = true
                  fileSizeLimitBytes     = 100000000
                  outputTemplate         = "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message}{NewLine}{Exception}"
                }
              }
            ]
          }
        }
      ]
      Enrich = ["FromLogContext", "WithThreadId"]
    }
  })

  jellyfin_logging_sha = sha256(local.jellyfin_logging_config)
}

resource "kubernetes_config_map_v1" "jellyfin_logging" {
  depends_on = [module.namespace["jellyfin"]]

  metadata {
    name      = "jellyfin-logging"
    namespace = local.jellyfin_ns
    labels    = local.jellyfin_labels
  }

  data = {
    "logging.json" = local.jellyfin_logging_config
  }
}


# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "jellyfin" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.jellyfin_config,
    kubernetes_persistent_volume_claim_v1.jellyfin_cache,
    kubernetes_persistent_volume_claim_v1.jellyfin_media_hdd,
    kubernetes_secret_v1.jellyfin_exporter,
  ]

  metadata {
    name      = "jellyfin"
    namespace = local.jellyfin_ns
    labels    = local.jellyfin_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.jellyfin_labels
    }

    template {
      metadata {
        labels = local.jellyfin_labels
        annotations = {
          "checksum/logging-config" = local.jellyfin_logging_sha
        }
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_node_selector

        # Jellyfin container
        container {
          name  = "jellyfin"
          image = local.jellyfin_image

          port {
            container_port = local.jellyfin_port
            name           = "http"
          }

          env {
            name  = "JELLYFIN_PublishedServerUrl"
            value = local.jellyfin_public_url
          }

          env {
            name  = "NVIDIA_VISIBLE_DEVICES"
            value = "all"
          }

          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "compute,video,utility"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }

          volume_mount {
            name       = "media-hdd"
            mount_path = "/media/hdd"
          }
          volume_mount {
            name       = "logging-config"
            mount_path = "/config/config/logging.json"
            sub_path   = "logging.json"
          }


          resources {
            requests = {
              cpu              = "1"
              memory           = "2Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.jellyfin_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.jellyfin_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # ---------------------------------------------------------------------
        # Prometheus exporter sidecar — scraped by otel-collector
        # ---------------------------------------------------------------------
        container {
          name  = "exporter"
          image = local.jellyfin_exporter_image

                    port {
                      container_port = local.jellyfin_exporter_port
                      name           = "metrics"
                    }

          args = [
            "--jellyfin.address=http://localhost:${local.jellyfin_port}",
            "--collector.transcoding",
            "--collector.tasks",
          ]

          env {
            name = "JELLYFIN_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.jellyfin_exporter.metadata[0].name
                key  = "token"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "96Mi"
            }
          }
        }


        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.jellyfin_config.metadata[0].name
          }
        }

        volume {
          name = "cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.jellyfin_cache.metadata[0].name
          }
        }

        volume {
          name = "media-hdd"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.jellyfin_media_hdd.metadata[0].name
          }
        }
        volume {
          name = "logging-config"
          config_map {
            name = kubernetes_config_map_v1.jellyfin_logging.metadata[0].name
          }
        }

      }
    }
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}


# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = local.jellyfin_ns
    labels    = local.jellyfin_labels
  }

  spec {
    selector = local.jellyfin_labels

    port {
      port        = local.jellyfin_port
      target_port = local.jellyfin_port
      name        = "http"
    }
  }
}

# Separate Service so the otel-collector scrape job can keep on a named "metrics"
# port without exposing the exporter alongside the WebUI on the main Service.
resource "kubernetes_service_v1" "jellyfin_exporter" {
  metadata {
    name      = "jellyfin-exporter"
    namespace = local.jellyfin_ns
    labels    = local.jellyfin_labels
  }

  spec {
    selector = local.jellyfin_labels

    port {
      port        = local.jellyfin_exporter_port
      target_port = local.jellyfin_exporter_port
      name        = "metrics"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "jellyfin_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.jellyfin]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "jellyfin"
      namespace = local.jellyfin_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.jellyfin_host, "tv.shdr.ch"]
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
          name = kubernetes_service_v1.jellyfin.metadata[0].name
          port = local.jellyfin_port
        }]
      }]
    }
  }
}
