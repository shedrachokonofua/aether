# =============================================================================
# qBittorrent — Torrent client behind Gluetun VPN
# =============================================================================
# Migrated from media_stack podman pod (gluetun + qbittorrent + exporter).
# Single Deployment, three containers sharing one network namespace.
# Config restored from VM export tarball into the ceph-rbd PVC after first apply.
# Downloads share the existing media-hdd NFS PVC at sub_path "downloads"
# (same path as sabnzbd; the existing *arr remap rules continue to work).

locals {
  qbittorrent_image          = "lscr.io/linuxserver/qbittorrent:latest"
  qbittorrent_exporter_image = "ghcr.io/martabal/qbittorrent-exporter:latest"
  gluetun_image              = "ghcr.io/qdm12/gluetun:latest"

  qbittorrent_host          = "qbittorrent.home.shdr.ch"
  qbittorrent_port          = 8080
  qbittorrent_exporter_port = 8090
  qbittorrent_ns            = local.jellyfin_ns
  qbittorrent_labels        = { app = "qbittorrent" }

  # Gluetun firewall needs the cluster pod + service CIDRs in OUTBOUND_SUBNETS
  # so liveness/readiness probes from kubelet and Service traffic to qbit/exporter
  # don't get black-holed when only the VPN tunnel is allowed out.
  cluster_pod_cidr     = "10.244.0.0/16"
  cluster_service_cidr = "10.96.0.0/12"
}

# =============================================================================
# Secret — VPN credentials + exporter qbit basic-auth
# =============================================================================

resource "kubernetes_secret_v1" "qbittorrent" {
  depends_on = [kubernetes_namespace_v1.media]

  metadata {
    name      = "qbittorrent"
    namespace = local.qbittorrent_ns
  }

  type = "Opaque"

  data = {
    vpn_provider          = var.secrets["qbittorrent.vpn_provider"]
    wireguard_private_key = var.secrets["qbittorrent.vpn_wireguard_private_key"]
    qbit_username         = var.secrets["qbittorrent.username"]
    qbit_password         = var.secrets["qbittorrent.password"]
  }
}

# =============================================================================
# Config PVCs (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "qbittorrent_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "qbittorrent-config"
    namespace = local.qbittorrent_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "gluetun_config" {
  depends_on = [kubernetes_namespace_v1.media, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "gluetun-config"
    namespace = local.qbittorrent_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "1Gi" }
    }
  }
}

# =============================================================================
# Deployment — gluetun + qbittorrent + exporter, shared netns
# =============================================================================

resource "kubernetes_deployment_v1" "qbittorrent" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.qbittorrent_config,
    kubernetes_persistent_volume_claim_v1.gluetun_config,
    kubernetes_persistent_volume_claim_v1.media_hdd,
    kubernetes_secret_v1.qbittorrent,
  ]

  metadata {
    name      = "qbittorrent"
    namespace = local.qbittorrent_ns
    labels    = local.qbittorrent_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.qbittorrent_labels
    }

    template {
      metadata {
        labels = local.qbittorrent_labels
      }

      spec {
        # ---------------------------------------------------------------------
        # Gluetun — WireGuard VPN, all pod traffic egresses through it
        # ---------------------------------------------------------------------
        container {
          name  = "gluetun"
          image = local.gluetun_image

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          env {
            name = "VPN_SERVICE_PROVIDER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.qbittorrent.metadata[0].name
                key  = "vpn_provider"
              }
            }
          }

          env {
            name  = "VPN_TYPE"
            value = "wireguard"
          }

          env {
            name = "WIREGUARD_PRIVATE_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.qbittorrent.metadata[0].name
                key  = "wireguard_private_key"
              }
            }
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          env {
            name  = "FIREWALL_INPUT_PORTS"
            value = "${local.qbittorrent_port},${local.qbittorrent_exporter_port}"
          }

          env {
            name  = "FIREWALL_OUTBOUND_SUBNETS"
            value = "${local.cluster_pod_cidr},${local.cluster_service_cidr}"
          }

          env {
            name  = "DNS_KEEP_NAMESERVER"
            value = "on"
          }

          volume_mount {
            name       = "gluetun-config"
            mount_path = "/gluetun"
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

          liveness_probe {
            exec {
              command = ["/gluetun-entrypoint", "healthcheck"]
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }
        }

        # ---------------------------------------------------------------------
        # qBittorrent — WebUI + torrent client (talks to gluetun via localhost)
        # ---------------------------------------------------------------------
        container {
          name  = "qbittorrent"
          image = local.qbittorrent_image

          env {
            name  = "PUID"
            value = "1000"
          }

          env {
            name  = "PGID"
            value = "1000"
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          env {
            name  = "WEBUI_PORT"
            value = tostring(local.qbittorrent_port)
          }

          volume_mount {
            name       = "qbittorrent-config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
            sub_path   = "downloads"
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "4"
              memory = "4Gi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.qbittorrent_port
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            tcp_socket {
              port = local.qbittorrent_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        # ---------------------------------------------------------------------
        # qBittorrent Prometheus exporter — scraped by otel-collector
        # ---------------------------------------------------------------------
        container {
          name  = "exporter"
          image = local.qbittorrent_exporter_image

          env {
            name  = "QBITTORRENT_BASE_URL"
            value = "http://localhost:${local.qbittorrent_port}"
          }

          env {
            name = "QBITTORRENT_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.qbittorrent.metadata[0].name
                key  = "qbit_username"
              }
            }
          }

          env {
            name = "QBITTORRENT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.qbittorrent.metadata[0].name
                key  = "qbit_password"
              }
            }
          }

          env {
            name  = "EXPORTER_PORT"
            value = tostring(local.qbittorrent_exporter_port)
          }

          env {
            name  = "LOG_LEVEL"
            value = "INFO"
          }

          env {
            name  = "ENABLE_HIGH_CARDINALITY"
            value = "false"
          }

          env {
            name  = "ENABLE_INCREASED_CARDINALITY"
            value = "false"
          }

          env {
            name  = "ENABLE_TRACKER"
            value = "true"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "qbittorrent-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.qbittorrent_config.metadata[0].name
          }
        }

        volume {
          name = "gluetun-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.gluetun_config.metadata[0].name
          }
        }

        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.media_hdd.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Services
# =============================================================================

resource "kubernetes_service_v1" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = local.qbittorrent_ns
    labels    = local.qbittorrent_labels
  }

  spec {
    selector = local.qbittorrent_labels

    port {
      port        = local.qbittorrent_port
      target_port = local.qbittorrent_port
      name        = "http"
    }
  }
}

# Separate Service so the otel-collector scrape job can keep on a named "metrics"
# port without exposing the exporter alongside the WebUI on the main Service.
resource "kubernetes_service_v1" "qbittorrent_exporter" {
  metadata {
    name      = "qbittorrent-exporter"
    namespace = local.qbittorrent_ns
    labels    = local.qbittorrent_labels
  }

  spec {
    selector = local.qbittorrent_labels

    port {
      port        = local.qbittorrent_exporter_port
      target_port = local.qbittorrent_exporter_port
      name        = "metrics"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "qbittorrent_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.qbittorrent]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "qbittorrent"
      namespace = local.qbittorrent_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.qbittorrent_host]
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
          name = kubernetes_service_v1.qbittorrent.metadata[0].name
          port = local.qbittorrent_port
        }]
      }]
    }
  }
}
