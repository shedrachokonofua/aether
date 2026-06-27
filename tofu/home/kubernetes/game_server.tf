# =============================================================================
# Game Server — steam-headless (Steam + Sunshine desktop streaming)
# =============================================================================
# Containerized replacement for the Bazzite game-server VM (1014). Runs a full
# Xfce desktop + Steam + Sunshine on the smith GPU (the same GTX 1660 Super that
# was passed through to the VM, now a k8s time-sliced GPU). Moonlight clients
# stream via a Cilium LoadBalancer.
#
# Foundation requirements (all in place on talos-smith):
#   - nvidia runtimeClass + nvidia.com/gpu (device plugin)
#   - NVIDIA_DRIVER_CAPABILITIES=all (graphics + video/NVENC) — verified
#   - /dev/uinput  (siderolabs/uinput extension + machine.kernel.modules)
#   - /dev/dri     (render node for headless EGL/gamescope)
#
# Seeding (post-apply, mirrors the sonarr VM->PVC restore pattern): the home PVC
# is seeded from the PBS backup of VM 1014 so the existing Sunshine pairings
# (macbook/xps/Xbox/Fold 6/Projector), apps.json, and PCSX2/RPCS3 flatpak
# configs carry over. ROM/ISO library stays on CephFS (/gaming), mounted as-is.

locals {
  game_server_image  = "docker.io/josh5/steam-headless:latest" # TODO pin by digest once a build is settled (no immutable named tag upstream)
  game_server_ns     = kubernetes_namespace_v1.games.metadata[0].name
  game_server_labels = { app = "game-server" }

  # Reuse the decommissioned VM's IP so existing Moonlight client configs keep
  # working without re-adding the host. VM 1014 must be retired to free it.
  game_server_vip = "10.0.3.13"

  # smith-only: the 1660 Super lives on talos-smith.
  gpu_smith_node_selector = merge(local.gpu_node_selector, {
    "kubernetes.io/hostname" = "talos-smith"
  })

  # Moonlight/Sunshine port family (base 47989). Web UI 47990; streaming uses
  # TCP 47984/48010 + UDP 47998-48002/48010.
  game_server_tcp_ports = [47984, 47989, 47990, 48010]
  game_server_udp_ports = [47998, 47999, 48000, 48002, 48010]
}

# =============================================================================
# Namespace — privileged PSA (steam-headless needs privileged + host devices)
# =============================================================================

resource "kubernetes_namespace_v1" "games" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "games"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# =============================================================================
# Secret — desktop/VNC password (Sunshine creds come from the seeded state file)
# =============================================================================
# USER_PASSWORD sets the root+default desktop password. SUNSHINE_USER/PASS are
# intentionally NOT set, so the seeded sunshine_state.json credentials + device
# pairings are preserved (the boot script only rewrites creds if those are set).

resource "kubernetes_secret_v1" "game_server" {
  metadata {
    name      = "game-server"
    namespace = local.game_server_ns
  }
  data = {
    USER_PASSWORD = var.secrets["game_server_password"]
  }
}

# =============================================================================
# Storage
# =============================================================================
# home  : configs, flatpak emulators (PCSX2/RPCS3), Sunshine state, Steam client
#         config. Seeded from the VM 1014 backup.
# games : Steam library install dir (/mnt/games). Football Manager re-downloads.
# gaming: existing CephFS ROM/ISO/save library at rootPath=/gaming (RWX, static).

resource "kubernetes_persistent_volume_claim_v1" "game_server_home" {
  depends_on = [kubernetes_namespace_v1.games, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "game-server-home"
    namespace = local.game_server_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources {
      requests = { storage = "100Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "game_server_games" {
  depends_on = [kubernetes_namespace_v1.games, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "game-server-games"
    namespace = local.game_server_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources {
      requests = { storage = "256Gi" }
    }
  }
}

# Static CephFS PV bound to the existing /gaming subtree (same data the VM used).
# Uses the ceph-csi-cephfs driver in static mode + the existing admin secret.
resource "kubernetes_persistent_volume_v1" "game_server_gaming" {
  depends_on = [kubernetes_storage_class_v1.cephfs]

  metadata {
    name = "game-server-gaming"
  }
  spec {
    capacity                         = { storage = "1Ti" } # nominal; static volume, not enforced
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "" # static, no provisioner

    persistent_volume_source {
      csi {
        driver        = "cephfs.csi.ceph.com"
        volume_handle = "game-server-gaming-static"
        volume_attributes = {
          clusterID    = local.ceph_fsid
          fsName       = local.cephfs_name
          staticVolume = "true"
          rootPath     = "/gaming"
          mounter      = "fuse"
        }
        node_stage_secret_ref {
          name      = kubernetes_secret_v1.ceph_csi_fs.metadata[0].name
          namespace = kubernetes_namespace_v1.ceph_csi_fs.metadata[0].name
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "game_server_gaming" {
  depends_on = [kubernetes_namespace_v1.games]

  metadata {
    name      = "game-server-gaming"
    namespace = local.game_server_ns
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume_v1.game_server_gaming.metadata[0].name
    resources {
      requests = { storage = "1Ti" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "game_server" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.game_server_home,
    kubernetes_persistent_volume_claim_v1.game_server_games,
    kubernetes_persistent_volume_claim_v1.game_server_gaming,
    kubernetes_secret_v1.game_server,
  ]

  metadata {
    name      = "game-server"
    namespace = local.game_server_ns
    labels    = local.game_server_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" } # single GPU, single writer (RWO home/games)

    selector {
      match_labels = local.game_server_labels
    }

    template {
      metadata {
        labels = local.game_server_labels
      }

      spec {
        runtime_class_name = "nvidia"
        node_selector      = local.gpu_smith_node_selector

        security_context {
          fs_group = 1000 # PUID/PGID — own the PVCs so the desktop user can write
        }

        container {
          name              = "steam-headless"
          image             = local.game_server_image
          image_pull_policy = "Always"

          security_context {
            privileged = true # required: /dev/uinput, /dev/dri, /dev/input, Xorg root rights
          }

          # --- identity / locale ---
          env {
            name  = "TZ"
            value = "America/Toronto"
          }
          env {
            name  = "USER"
            value = "default"
          }
          env {
            name  = "PUID"
            value = "1000"
          }
          env {
            name  = "PGID"
            value = "1000"
          }
          env {
            name = "USER_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.game_server.metadata[0].name
                key  = "USER_PASSWORD"
              }
            }
          }

          # --- streaming / desktop mode ---
          env {
            name  = "MODE"
            value = "primary" # own Xorg + Sunshine
          }
          env {
            name  = "WEB_UI_MODE"
            value = "none" # Sunshine/Moonlight only (no noVNC), matches upstream k8s example
          }
          env {
            name  = "ENABLE_STEAM"
            value = "true"
          }
          env {
            name  = "ENABLE_SUNSHINE"
            value = "true"
          }
          env {
            name  = "ENABLE_EVDEV_INPUTS"
            value = "true" # capture /dev/input (controllers) via Xorg evdev
          }

          # --- NVIDIA ---
          # graphics+video required for GPU desktop rendering + NVENC. Do NOT set
          # NVIDIA_VISIBLE_DEVICES — the device plugin injects the allocated GPU.
          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "all"
          }

          # --- mounts ---
          volume_mount {
            name       = "home"
            mount_path = "/home/default"
          }
          volume_mount {
            name       = "games"
            mount_path = "/mnt/games"
          }
          volume_mount {
            name       = "gaming"
            # /var/mnt/gaming matches the path baked into the seeded RPCS3
            # games.yml + Steam shortcuts.vdf (Bazzite resolved /mnt -> /var/mnt),
            # so the emulator library + Big Picture entries work without rewrites.
            mount_path = "/var/mnt/gaming"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }

          dynamic "port" {
            for_each = toset(concat(local.game_server_tcp_ports, [for p in local.game_server_udp_ports : p]))
            content {
              container_port = port.value
            }
          }

          resources {
            requests = {
              cpu              = "2"
              memory           = "4Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              memory           = "16Gi"
              "nvidia.com/gpu" = "1"
            }
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.game_server_home.metadata[0].name
          }
        }
        volume {
          name = "games"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.game_server_games.metadata[0].name
          }
        }
        volume {
          name = "gaming"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.game_server_gaming.metadata[0].name
          }
        }
        # Large /dev/shm for Steam/Proton/encoders (default 64Mi is too small).
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "4Gi"
          }
        }
      }
    }
  }
}

# =============================================================================
# Service — Cilium LoadBalancer (Moonlight TCP + UDP on one VIP)
# =============================================================================

resource "kubernetes_service_v1" "game_server" {
  metadata {
    name      = "game-server"
    namespace = local.game_server_ns
    labels    = local.game_server_labels
    annotations = {
      "io.cilium/lb-ipam-ips" = local.game_server_vip
    }
  }

  spec {
    type                    = "LoadBalancer"
    selector                = local.game_server_labels
    external_traffic_policy = "Local" # preserve client source IP for Sunshine lan/wan origin checks

    dynamic "port" {
      for_each = toset(local.game_server_tcp_ports)
      content {
        name        = "tcp-${port.value}"
        port        = port.value
        target_port = port.value
        protocol    = "TCP"
      }
    }
    dynamic "port" {
      for_each = toset(local.game_server_udp_ports)
      content {
        name        = "udp-${port.value}"
        port        = port.value
        target_port = port.value
        protocol    = "UDP"
      }
    }
  }
}
