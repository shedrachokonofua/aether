# =============================================================================
# slskd — Soulseek client behind its own Gluetun VPN sidecar
# =============================================================================
# Mirrors the qbittorrent pattern: one Deployment, gluetun + app containers
# sharing a single network namespace so all app egress leaves through the
# WireGuard tunnel (ProtonVPN).
#
# It does NOT share qBittorrent's gluetun: a gluetun sidecar owns its pod's
# network namespace, so a second Deployment cannot borrow it. Same VPN account
# and WireGuard key, separate tunnel and lifecycle.
#
# Difference from qBittorrent: port forwarding is enabled here. Soulseek peers
# must be able to connect *in* for uploads to work, so gluetun requests a
# forwarded port from ProtonVPN (NAT-PMP) and slskd's native VPN integration
# discovers it from gluetun's control server and rebinds its listen port.
#
# Storage layout on the media-hdd NFS share (/mnt/hdd/data):
#   downloads/slskd/{incomplete,complete}  <- mounted rw at /downloads/slskd
#   music/                                 <- mounted READ-ONLY at /music
# Nothing else on the share is mounted, so the pod cannot reach movies/, tv/,
# nextcloud/, immich/, adult/, backups/ even if the share config were wrong.

locals {
  slskd_image         = "ghcr.io/slskd/slskd:latest"
  slskd_gluetun_image = "ghcr.io/qdm12/gluetun:latest"
  slskd_host          = "slskd.home.shdr.ch"
  slskd_port          = 5030
  slskd_listen_port   = 50300
  slskd_ns            = module.namespace["slskd"].name
  slskd_labels        = { app = "slskd" }
}

# =============================================================================
# Secrets
# =============================================================================
# VPN credentials for gluetun (consumed as env vars).

resource "kubernetes_secret_v1" "slskd_vpn" {
  depends_on = [module.namespace["slskd"]]

  metadata {
    name      = "slskd-vpn"
    namespace = local.slskd_ns
  }

  type = "Opaque"

  data = {
    # Same ProtonVPN account/key as qbittorrent — a separate tunnel, not a
    # shared gluetun. If ProtonVPN ever refuses two concurrent sessions on one
    # key, mint a second WireGuard config and point this at it.
    vpn_provider          = var.secrets["qbittorrent.vpn_provider"]
    wireguard_private_key = var.secrets["qbittorrent.vpn_wireguard_private_key"]
  }
}

# The rendered slskd.yml. This lives in a Secret rather than a ConfigMap because
# slskd's YAML file overrides environment variables (and its `~` is an explicit
# null that would blank an env-injected value), so the credentials have to be in
# the file itself. See the header of slskd.yml.tftpl.
resource "kubernetes_secret_v1" "slskd_config" {
  depends_on = [module.namespace["slskd"]]

  metadata {
    name      = "slskd-config"
    namespace = local.slskd_ns
  }

  type = "Opaque"

  data = {
    "slskd.yml" = templatefile("${path.module}/slskd.yml.tftpl", {
      slsk_username       = var.secrets["slskd.slsk_username"]
      slsk_password       = var.secrets["slskd.slsk_password"]
      web_username        = "shdrch"
      web_password        = var.secrets["slskd.web_password"]
      jwt_key             = var.secrets["slskd.jwt_key"]
      rotating_proxy_host = split(":", var.rotating_proxy_addr)[0]
      rotating_proxy_port = split(":", var.rotating_proxy_addr)[1]
    })
  }
}

# Gluetun control server authorization. Without a role covering a route the
# middleware answers 401, which left slskd unable to read the forwarded port.
# Only the two read-only routes slskd polls are opened; every other route
# (including the mutating PUT ones) keeps denying unauthenticated callers.
resource "kubernetes_config_map_v1" "slskd_gluetun_auth" {
  depends_on = [module.namespace["slskd"]]

  metadata {
    name      = "slskd-gluetun-auth"
    namespace = local.slskd_ns
  }

  data = {
    "config.toml" = <<-TOML
      [[roles]]
      name = "slskd"
      routes = ["GET /v1/publicip/ip", "GET /v1/portforward"]
      auth = "none"
    TOML
  }
}

# =============================================================================
# PVCs
# =============================================================================
# /app — slskd database, logs, and the disk-backed share cache.

resource "kubernetes_persistent_volume_claim_v1" "slskd_app" {
  depends_on = [module.namespace["slskd"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "slskd-app"
    namespace = local.slskd_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "10Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "slskd_gluetun_config" {
  depends_on = [module.namespace["slskd"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "gluetun-config"
    namespace = local.slskd_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "1Gi" }
    }
  }
}

# media-hdd NFS — same share qbittorrent/sabnzbd/lidarr use. Per-namespace
# static PV/PVC pair, matching the qbittorrent approach.
resource "kubernetes_persistent_volume_v1" "slskd_media_hdd" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "slskd-media-hdd"
  }

  spec {
    capacity                         = { storage = "1Ti" }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "slskd-media-hdd"
        read_only     = false
        volume_attributes = {
          server = var.nfs_server_ip
          share  = "/mnt/hdd/data"
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "slskd_media_hdd" {
  depends_on = [module.namespace["slskd"], kubernetes_persistent_volume_v1.slskd_media_hdd]

  metadata {
    name      = "media-hdd"
    namespace = local.slskd_ns
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_hdd.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.slskd_media_hdd.metadata[0].name

    resources {
      requests = { storage = "1Ti" }
    }
  }
}

# =============================================================================
# Deployment — gluetun + slskd, shared netns
# =============================================================================

resource "kubernetes_deployment_v1" "slskd" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.slskd_app,
    kubernetes_persistent_volume_claim_v1.slskd_gluetun_config,
    kubernetes_persistent_volume_claim_v1.slskd_media_hdd,
    kubernetes_secret_v1.slskd_vpn,
    kubernetes_secret_v1.slskd_config,
    kubernetes_config_map_v1.slskd_gluetun_auth,
  ]

  metadata {
    name      = "slskd"
    namespace = local.slskd_ns
    labels    = local.slskd_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.slskd_labels
    }

    template {
      metadata {
        labels = local.slskd_labels
        annotations = {
          # Restart the pod when the rendered config Secret changes; several
          # slskd options are [RequiresRestart].
          "reloader.stakater.com/auto" = "true"
        }
      }

      spec {
        termination_grace_period_seconds = 120

        # ---------------------------------------------------------------------
        # slskd validates that its download directories already exist and will
        # not create them (it exits with "specifies a non-existent directory").
        # Create them as uid 1000, which owns downloads/ on the NFS share, so
        # the tree is owned correctly by construction — no root, no chown. The
        # share sets setgid on downloads/, so the group is inherited as `users`.
        # ---------------------------------------------------------------------
        init_container {
          name    = "init-dirs"
          image   = local.slskd_image
          command = ["/bin/mkdir", "-p", "/downloads/slskd/incomplete", "/downloads/slskd/complete"]

          security_context {
            run_as_user  = 1000
            run_as_group = 1000
          }

          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
            sub_path   = "downloads"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }

        # ---------------------------------------------------------------------
        # Gluetun — WireGuard VPN + NAT-PMP port forwarding
        # ---------------------------------------------------------------------
        container {
          name  = "gluetun"
          image = local.slskd_gluetun_image

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          env {
            name = "VPN_SERVICE_PROVIDER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.slskd_vpn.metadata[0].name
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
                name = kubernetes_secret_v1.slskd_vpn.metadata[0].name
                key  = "wireguard_private_key"
              }
            }
          }

          env {
            name  = "TZ"
            value = "America/Toronto"
          }

          # Only the Web UI port needs a static hole. The Soulseek port is
          # dynamic and gluetun opens the forwarded port itself once NAT-PMP
          # returns one.
          env {
            name  = "FIREWALL_INPUT_PORTS"
            value = tostring(local.slskd_port)
          }

          # Cluster CIDRs so kubelet probes and Service traffic work, plus the
          # rotating SOCKS5 proxy on the home gateway stack: all Soulseek
          # traffic goes through it (see slskd.yml.tftpl connection.proxy),
          # reaching the LAN directly rather than through the VPN tunnel.
          env {
            name  = "FIREWALL_OUTBOUND_SUBNETS"
            value = "${local.cluster_pod_cidr},${local.cluster_service_cidr},${split(":", var.rotating_proxy_addr)[0]}/32"
          }

          env {
            name  = "DNS_KEEP_NAMESERVER"
            value = "on"
          }

          # Root cause of the ~60s session RST loop (diagnosed 2026-08-03):
          # slsknet.org fronts its server with protection gear (forged RSTs,
          # TTL/TOS fingerprint differs from real server packets) that polices
          # connections from shared ProtonVPN exit IPs. Every P2P-optimized
          # Proton exit we tested (San Jose, Miami, Montréal, Bucharest, London)
          # went deaf seconds after login and RST ~60s in, while the identical
          # active session from a residential IP stayed healthy. Client config
          # is irrelevant; the IP's reputation is the trigger.
          #
          # Mitigation: all Soulseek traffic rides the rotating residential
          # SOCKS5 proxy (slskd.yml.tftpl connection.proxy) — the one IP class
          # the front-end does not police (probe held 7+ min vs 60-121s on
          # every Proton exit). Gluetun stays as the pod's default egress and
          # safety interlock only. Port forwarding stays off: inbound
          # reachability is impossible behind a SOCKS5 proxy and was proven
          # irrelevant to session stability; the cost is only that transfers
          # with firewalled peers fail.
          env {
            name  = "VPN_PORT_FORWARDING"
            value = "off"
          }

          # Control server: bind to IPv4 loopback only, so nothing outside this
          # pod's network namespace can reach it (it also exposes mutating
          # routes). slskd is pinned to 127.0.0.1 to match — its HTTP client
          # resolves "localhost" to ::1, which a v4-only bind would miss.
          env {
            name  = "HTTP_CONTROL_SERVER_ADDRESS"
            value = "127.0.0.1:8000"
          }

          # Routes not covered by a role require auth and return 401. Grant
          # unauthenticated access to exactly the two read-only routes slskd
          # polls; everything else (including PUT routes) stays denied.
          env {
            name  = "HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH"
            value = "/etc/gluetun-auth/config.toml"
          }

          volume_mount {
            name       = "gluetun-config"
            mount_path = "/gluetun"
          }

          volume_mount {
            name       = "gluetun-auth"
            mount_path = "/etc/gluetun-auth"
            read_only  = true
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
        # slskd — reaches the VPN and gluetun's control server via localhost
        # ---------------------------------------------------------------------
        container {
          name  = "slskd"
          image = local.slskd_image

          port {
            container_port = local.slskd_port
            name           = "http"
          }

          # Run as 1000:1000 so files written to the shared NFS downloads
          # directory match what qbittorrent/sabnzbd/*arr/Jellyfin expect.
          # Without this the image runs as root.
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

          # Config lives outside SLSKD_APP_DIR (/app) on its own read-only
          # Secret mount; slskd explicitly supports a config path outside the
          # app directory.
          env {
            name  = "SLSKD_CONFIG"
            value = "/config/slskd.yml"
          }

          volume_mount {
            name       = "app"
            mount_path = "/app"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }

          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
            sub_path   = "downloads"
          }

          # Music library — read-only, slskd only ever serves from it.
          volume_mount {
            name       = "music"
            mount_path = "/music"
            sub_path   = "music"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2"
              memory = "2Gi"
            }
          }

          # slskd maps its health endpoint at /health (the image's own
          # HEALTHCHECK uses it) and it is not behind Web UI auth.
          liveness_probe {
            http_get {
              path = "/health"
              port = local.slskd_port
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.slskd_port
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }
        }

        volume {
          name = "app"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.slskd_app.metadata[0].name
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.slskd_config.metadata[0].name
          }
        }

        volume {
          name = "gluetun-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.slskd_gluetun_config.metadata[0].name
          }
        }

        volume {
          name = "gluetun-auth"
          config_map {
            name = kubernetes_config_map_v1.slskd_gluetun_auth.metadata[0].name
          }
        }

        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.slskd_media_hdd.metadata[0].name
          }
        }

        volume {
          name = "music"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.slskd_media_hdd.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring
    # only this field prevents perpetual Terraform rollouts.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

# =============================================================================
# Services
# =============================================================================

resource "kubernetes_service_v1" "slskd" {
  metadata {
    name      = "slskd"
    namespace = local.slskd_ns
    labels    = local.slskd_labels
  }

  spec {
    selector = local.slskd_labels

    port {
      port        = local.slskd_port
      target_port = local.slskd_port
      name        = "http"
    }
  }
}

# Separate Service so the otel-collector scrape job can key off a named
# "metrics" port, matching the qbittorrent-exporter arrangement. slskd serves
# /metrics on the same port as the Web UI.
resource "kubernetes_service_v1" "slskd_metrics" {
  metadata {
    name      = "slskd-metrics"
    namespace = local.slskd_ns
    labels    = local.slskd_labels
  }

  spec {
    selector = local.slskd_labels

    port {
      port        = local.slskd_port
      target_port = local.slskd_port
      name        = "metrics"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "slskd_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.slskd]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "slskd"
      namespace = local.slskd_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.slskd_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.slskd.metadata[0].name
          port = local.slskd_port
        }]
      }]
    }
  }
}
