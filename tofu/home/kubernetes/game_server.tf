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
  game_server_ns     = module.namespace["games"].name
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
# Boot-fix script — runs (as root) via a postStart hook before the X session +
# Sunshine start. Fixes three steam-headless-in-headless-container issues:
#   1. light-locker (XFCE screen locker) hits a glib assertion and crash-loops
#      the desktop session -> disable its autostart + binary.
#   2. Sunshine's "main loop" IS its GTK system-tray loop, which quits unless it
#      can reach the desktop StatusNotifierWatcher. Drop file caps (so AT_SECURE
#      stops glib ignoring the bus env), and source a shim that hands Sunshine
#      the running xfce4-panel session bus + NO_AT_BRIDGE (skip the a11y bus).
#   3. start-dumb-udev.sh restarts Xorg when Sunshine uinput devices appear;
#      current Sunshine creates those devices at startup, so the restart tears
#      down Sunshine, removes the devices, clears the guard, and loops forever.
# =============================================================================

resource "kubernetes_config_map_v1" "game_server_bootfix" {
  metadata {
    name      = "game-server-bootfix"
    namespace = local.game_server_ns
  }
  data = {
    "boot-fix.sh" = <<-EOT
      #!/bin/sh
      # Disable light-locker (crash-loops the headless session).
      if [ -f /etc/xdg/autostart/light-locker.desktop ]; then
        printf '\nHidden=true\nX-GNOME-Autostart-enabled=false\n' >> /etc/xdg/autostart/light-locker.desktop
      fi
      chmod 000 /usr/bin/light-locker 2>/dev/null || true
      # Sunshine creates uinput devices at startup. Upstream dumb-udev "fixes"
      # input two broken ways: (1) it restarts Xorg when the devices appear (a
      # crash loop -- the restart tears down Sunshine, which recreates the
      # devices), and (2) it runs udevd under `unshare --net`, putting udevd in a
      # different network namespace than Xorg. udev hotplug events are per-netns,
      # so Xorg never receives them and input never works. Fix both: mask the
      # net-naming rules so a main-ns udevd can't rename the pod NIC, drop
      # `unshare --net` so udevd shares Xorg's namespace (hotplug reaches Xorg),
      # and replace the Xorg restart with an input-only `udevadm trigger`. No
      # Xorg restart -> the crash loop cannot return.
      for r in 73-special-net-names 75-net-description 80-net-setup-link 81-net-dhcp; do
        ln -sf /dev/null "/etc/udev/rules.d/$r.rules"
      done
      if [ -f /usr/bin/start-dumb-udev.sh ]; then
        sed -i \
          -e 's@unshare --net @@g' \
          -e 's@.*supervisorctl restart xorg.*@udevadm trigger --action=add --subsystem-match=input || true  # input hotplug by boot-fix@' \
          -e 's@.*rm -f.*xorg-restarted.*@: # guard kept persistent by boot-fix@' \
          /usr/bin/start-dumb-udev.sh
        # Clear any separate-ns udevd that already started so the patched script
        # relaunches udevd in the main (Xorg) namespace cleanly.
        udevadm control --exit 2>/dev/null || true
        pkill -x systemd-udevd 2>/dev/null || true
        pkill -x udevd 2>/dev/null || true
        rm -f /run/udev/control
        pkill -f '/usr/bin/start-dumb-udev.sh' 2>/dev/null || true
      fi
      # Sunshine tray fix: drop caps + write a shim (sourced by start-sunshine.sh)
      # that points Sunshine at the live xfce4-panel session bus + NO_AT_BRIDGE.
      setcap -r /usr/bin/sunshine 2>/dev/null || true
      {
        echo 'export NO_AT_BRIDGE=1'
        echo '_p=$(pgrep -x xfce4-panel | head -1)'
        echo '[ -n "$_p" ] && export DBUS_SESSION_BUS_ADDRESS=$(tr "\0" "\n" < /proc/$_p/environ 2>/dev/null | grep "^DBUS_SESSION_BUS_ADDRESS=" | cut -d= -f2-)'
      } > /usr/local/bin/gs-sunshine-env.sh
      chmod +x /usr/local/bin/gs-sunshine-env.sh
      if ! grep -q gs-sunshine-env /usr/bin/start-sunshine.sh; then
        sed -i '/# Start the sunshine server/i . /usr/local/bin/gs-sunshine-env.sh' /usr/bin/start-sunshine.sh
      fi
    EOT
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
  depends_on = [module.namespace["games"], kubernetes_storage_class_v1.ceph_rbd]

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
  depends_on = [module.namespace["games"], kubernetes_storage_class_v1.ceph_rbd]

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
    # Explicit non-default class name (no such StorageClass exists, so nothing
    # dynamically provisions). Must match the PVC. NOT "" — the TF provider drops
    # empty-string, letting the DefaultStorageClass admission inject ceph-rbd,
    # which then won't bind to this static PV.
    storage_class_name = "cephfs-static"

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
          namespace = module.namespace["ceph-csi-cephfs"].name
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "game_server_gaming" {
  depends_on = [module.namespace["games"]]

  metadata {
    name      = "game-server-gaming"
    namespace = local.game_server_ns
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "cephfs-static" # must match the PV; not "" (provider drops it -> default injected)
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

  # Don't block apply on rollout — steam-headless installs the NVIDIA driver and
  # starts Xorg/Steam/Sunshine on first boot (slow, and likely needs a round of
  # tuning). Manage readiness out-of-band.
  wait_for_rollout = false

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
        annotations = {
          "aether.shdr.ch/bootfix-sha" = sha256(kubernetes_config_map_v1.game_server_bootfix.data["boot-fix.sh"])
        }
      }

      spec {
        runtime_class_name = "nvidia"
        node_selector      = local.gpu_neo_node_selector

        security_context {
          fs_group = 1000 # PUID/PGID — own the PVCs so the desktop user can write
          # Don't recursively chown every volume on each mount — the 1Ti CephFS
          # /gaming library is already owned by 1000 (from the old VM), so root
          # matches and kubelet skips it; only the empty Steam-library PVC chowns.
          fs_group_change_policy = "OnRootMismatch"
        }

        container {
          name              = "steam-headless"
          image             = local.game_server_image
          image_pull_policy = "Always"

          security_context {
            privileged = true # required: /dev/uinput, /dev/dri, /dev/input, Xorg root rights
          }

          # Run boot-fix (light-locker disable + Sunshine tray/dbus fix) as root,
          # before the X session + Sunshine launch.
          lifecycle {
            post_start {
              exec {
                command = ["sh", "/opt/gs-bootfix/boot-fix.sh"]
              }
            }
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
            name = "gaming"
            # /var/mnt/gaming matches the path baked into the seeded RPCS3
            # games.yml + Steam shortcuts.vdf (Bazzite resolved /mnt -> /var/mnt),
            # so the emulator library + Big Picture entries work without rewrites.
            mount_path = "/var/mnt/gaming"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "bootfix"
            mount_path = "/opt/gs-bootfix"
            read_only  = true
          }

          dynamic "port" {
            for_each = toset(concat(local.game_server_tcp_ports, [for p in local.game_server_udp_ports : p]))
            content {
              container_port = port.value
            }
          }

          resources {
            requests = {
              # Guaranteed CPU share for the emulator: RPCS3 (PS3) is brutally
              # CPU-bound and was being starved by smith's ~52 co-tenant pods.
              # An 8-core request floors its CFS weight under contention; with
              # no CPU *limit* it still bursts higher when the node is idle, and
              # neighbors reclaim these cycles whenever nobody is streaming.
              cpu              = "4"
              memory           = "8Gi"
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
        volume {
          name = "bootfix"
          config_map {
            name         = kubernetes_config_map_v1.game_server_bootfix.metadata[0].name
            default_mode = "0755"
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
    type     = "LoadBalancer"
    selector = local.game_server_labels
    # The VIP's L2 announcement lease lands on an arbitrary node (e.g. neo), but
    # the pod is GPU-pinned to smith. With "Local" the announcing node drops
    # traffic when it has no local endpoint -> connection refused. "Cluster" lets
    # any node route to the pod. Sunshine sees a private/LAN SNAT source, which
    # still satisfies its lan/wan origin check.
    external_traffic_policy = "Cluster"

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
