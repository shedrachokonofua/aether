# =============================================================================
# ImmichFrame — server-rendered slideshow for the Lenovo Smart Frame
# =============================================================================
# Companion to Immich: serves a web slideshow (clock/weather overlays, Ken
# Burns) that the frame's Android client displays. The frame itself never
# holds an Immich API key — it only reaches this web client, and only through
# the gateway Caddy's frame-scoped :8444 listener (VyOS permits the frame
# alone; see ansible/playbooks/home_router/ and the gateway Caddyfile).
# Config lives here so the frame's behavior is versioned; the device is dumb.

locals {
  immichframe_host   = "immichframe.home.shdr.ch"
  immichframe_image  = "ghcr.io/immichframe/immichframe:v1.0.37.0"
  immichframe_port   = 8080
  immichframe_labels = { app = "immichframe" }

  # Albums owned by the dedicated low-privilege `frame` Immich user.
  immichframe_album_photos = "621f6648-baea-4141-b4ee-9739ae3c0494" # Frame — Photos
  immichframe_album_art    = "734cdb38-5f39-4a1e-ad33-e8e73f8a408d" # Frame — Generated Art
}

# Settings.yml is a secret because it embeds the frame user's API key.
# Keep overrides minimal (upstream warns against copying full defaults).
resource "kubernetes_secret_v1" "immichframe_config" {
  depends_on = [module.namespace["immich"]]

  metadata {
    name      = "immichframe-config"
    namespace = module.namespace["immich"].name
  }

  data = {
    "Settings.yml" = yamlencode({
      General = {
        Interval           = 60
        TransitionDuration = 2
        ShowClock          = true
        ImageZoom          = true
        # Portrait 1080x1920 panel — splitview only helps landscape frames.
        Layout = "single"
      }
      Accounts = [{
        # In-cluster hop; never round-trips through the gateway.
        ImmichServerUrl = "http://immich-server.${local.immich_namespace}.svc.cluster.local:${local.immich_server_port}"
        ApiKey          = var.secrets["immich.frame_api_key"]
        ShowMemories    = true
        Albums = [
          local.immichframe_album_photos,
          local.immichframe_album_art,
        ]
      }]
    })
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "immichframe" {
  # No depends_on to immich_server: ImmichFrame retries until Immich answers,
  # and the ordering edge would drag the immich-ml dependency chain into
  # targeted plans (risking reverts of live GPU-node-selector state).
  depends_on = [kubernetes_secret_v1.immichframe_config]

  metadata {
    name      = "immichframe"
    namespace = module.namespace["immich"].name
    labels    = local.immichframe_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.immichframe_labels
    }

    template {
      metadata {
        labels = local.immichframe_labels
      }

      spec {
        container {
          name  = "immichframe"
          image = local.immichframe_image

          port {
            container_port = local.immichframe_port
            name           = "http"
          }

          env {
            name  = "IMMICHFRAME_CONFIG_PATH"
            value = "/etc/immichframe"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/immichframe"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.immichframe_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "immichframe" {
  depends_on = [kubernetes_deployment_v1.immichframe]

  metadata {
    name      = "immichframe"
    namespace = module.namespace["immich"].name
    labels    = local.immichframe_labels
  }

  spec {
    selector = local.immichframe_labels

    port {
      port        = local.immichframe_port
      target_port = local.immichframe_port
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_manifest" "immichframe_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.immichframe]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "immichframe"
      namespace = local.immich_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.immichframe_host]
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
          name = kubernetes_service_v1.immichframe.metadata[0].name
          port = local.immichframe_port
        }]
      }]
    }
  }
}
