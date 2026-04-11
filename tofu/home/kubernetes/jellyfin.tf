# =============================================================================
# Jellyfin — Media Server
# =============================================================================
# Migrated from media_stack podman quadlet to Kubernetes.
# GPU transcoding via talos-neo (RTX Pro 6000).
# Includes rclone sidecar for nzbdav WebDAV mount.

locals {
  jellyfin_image  = "docker.io/jellyfin/jellyfin:latest"
  # Gateway API matches the Host header from Caddy (header_up Host …); public URL is tv.shdr.ch.
  jellyfin_gateway_hostname = "jellyfin.apps.home.shdr.ch"
  jellyfin_public_url       = "https://tv.shdr.ch"
  jellyfin_port             = 8096
  jellyfin_ns     = kubernetes_namespace_v1.media.metadata[0].name
  jellyfin_labels = { app = "jellyfin" }

  rclone_image = "rclone/rclone:latest"
}

# =============================================================================
# Namespace
# =============================================================================

resource "kubernetes_namespace_v1" "media" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "media"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# =============================================================================
# PVCs
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "jellyfin_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

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
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

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
  depends_on = [kubernetes_namespace_v1.media, kubernetes_persistent_volume_v1.media_hdd]

  metadata {
    name      = "media-hdd"
    namespace = local.jellyfin_ns
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

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "jellyfin" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.jellyfin_config,
    kubernetes_persistent_volume_claim_v1.jellyfin_cache,
    kubernetes_persistent_volume_claim_v1.media_hdd,
    kubernetes_service_v1.nzbdav,
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
            name              = "nzbdav"
            mount_path        = "/mnt/nzbdav"
            read_only         = true
            mount_propagation = "HostToContainer"
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

        # Rclone sidecar — mounts nzbdav WebDAV as FUSE filesystem
        container {
          name  = "rclone-nzbdav"
          image = local.rclone_image

          command = ["rclone", "mount", "nzb-dav:", "/mnt/nzbdav",
            "--config=/config/rclone.conf",
            "--vfs-cache-mode=full",
            "--buffer-size=1024M",
            "--dir-cache-time=1s",
            "--vfs-cache-max-size=5G",
            "--vfs-cache-max-age=180m",
            "--links",
            "--use-cookies",
            "--allow-other",
            "--allow-non-empty",
          ]

          security_context {
            privileged = true
          }

          volume_mount {
            name              = "nzbdav"
            mount_path        = "/mnt/nzbdav"
            mount_propagation = "Bidirectional"
          }

          volume_mount {
            name       = "rclone-config"
            mount_path = "/config"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "2Gi"
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
            claim_name = kubernetes_persistent_volume_claim_v1.media_hdd.metadata[0].name
          }
        }

        volume {
          name = "nzbdav"
          empty_dir {}
        }

        volume {
          name = "rclone-config"
          config_map {
            name = kubernetes_config_map_v1.rclone_nzbdav.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Rclone ConfigMap
# =============================================================================

resource "kubernetes_config_map_v1" "rclone_nzbdav" {
  depends_on = [kubernetes_namespace_v1.media]

  metadata {
    name      = "rclone-nzbdav"
    namespace = local.jellyfin_ns
  }

  data = {
    "rclone.conf" = <<-EOT
      [nzb-dav]
      type = webdav
      url = http://nzbdav.${local.jellyfin_ns}.svc.cluster.local:3000
      vendor = other
    EOT
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
      hostnames = [local.jellyfin_gateway_hostname]
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
