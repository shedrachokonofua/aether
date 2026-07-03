# =============================================================================
# Open Design — Local-first, open-source Claude Design alternative
# =============================================================================
# Single daemon container (Node.js) serving both the API and the built Next.js
# static export on :7456. The daemon enforces its own bearer-token auth via
# OD_API_TOKEN — no sidecar proxy needed.
#
# State is SQLite + local files under /app/.od — PVC-backed (Ceph RBD),
# 1 replica, Recreate strategy. No HPA (SQLite is single-writer).
#
# Upstream: https://github.com/nexu-io/open-design
# Image:    registry.gitlab.home.shdr.ch/so/aether/composer-api/open-design:0.11.0-amd64
#          (built in-cluster via BuildKit on an amd64 node from deploy/Dockerfile
#           @ open-design-v0.11.0, pushed to the composer-api project's container
#           registry since upstream does not publish a public ghcr image.)


locals {
  od_image     = "registry.gitlab.home.shdr.ch/so/aether/composer-api/open-design:0.11.0-amd64"
  od_host      = "open-design.home.shdr.ch"
  od_web_port  = 7456
  od_ns        = module.namespace["open-design"].name
  od_labels    = { app = "open-design" }
  od_api_token = var.secrets["open_design.api_token"]

  od_registry_host = "registry.gitlab.home.shdr.ch"
  od_registry_user = var.secrets["gitlab.root_email"]
  od_registry_pass = var.secrets["gitlab.root_password"]
}

# ---------------------------------------------------------------------------
# Secret — GitLab Container Registry pull creds (for the locally-built OD image)
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "open_design_registry" {
  depends_on = [module.namespace["open-design"]]

  metadata {
    name      = "open-design-registry"
    namespace = local.od_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.od_registry_host) = {
          username = local.od_registry_user
          password = local.od_registry_pass
          auth     = base64encode("${local.od_registry_user}:${local.od_registry_pass}")
        }
      }
    })
  }
}

# ---------------------------------------------------------------------------
# Secret — daemon env (API token)
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "open_design_env" {
  depends_on = [module.namespace["open-design"]]

  metadata {
    name      = "open-design-env"
    namespace = local.od_ns
  }

  data = {
    OD_API_TOKEN = local.od_api_token
  }
}

# ---------------------------------------------------------------------------
# PVC — SQLite + file state
# ---------------------------------------------------------------------------
resource "kubernetes_persistent_volume_claim_v1" "open_design_data" {
  depends_on = [module.namespace["open-design"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "open-design-data"
    namespace = local.od_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "10Gi" } }
  }

  lifecycle { prevent_destroy = true }
}

# ---------------------------------------------------------------------------
# Deployment — daemon (single container)
# ---------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "open_design" {
  depends_on = [
    kubernetes_secret_v1.open_design_env,
    kubernetes_secret_v1.open_design_registry,
    kubernetes_persistent_volume_claim_v1.open_design_data,
  ]

  wait_for_rollout = false

  metadata {
    name      = "open-design"
    namespace = local.od_ns
    labels    = local.od_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector { match_labels = local.od_labels }

    template {
      metadata { labels = local.od_labels }

      spec {
        automount_service_account_token = false
        enable_service_links            = false

        image_pull_secrets {
          name = kubernetes_secret_v1.open_design_registry.metadata[0].name
        }

        security_context {
          fs_group               = 1001
          fs_group_change_policy = "Always"
        }

        container {
          name  = "open-design"
          image = local.od_image

          env {
            name = "OD_API_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.open_design_env.metadata[0].name
                key  = "OD_API_TOKEN"
              }
            }
          }
          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "NODE_OPTIONS"
            value = "--max-old-space-size=192"
          }
          env {
            name  = "OPEN_DESIGN_ALLOWED_ORIGINS"
            value = "https://${local.od_host}"
          }
          env {
            name  = "OD_BIND_HOST"
            value = "0.0.0.0"
          }

          port {
            container_port = local.od_web_port
            name           = "http"
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/.od"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "200m", memory = "256Mi" }
            limits   = { cpu = "1000m", memory = "1024Mi" }
          }

          security_context {
            run_as_user                = 1001
            run_as_group               = 1001
            run_as_non_root            = true
            allow_privilege_escalation = false
            privileged                 = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.od_web_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.od_web_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.open_design_data.metadata[0].name
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Service — routes to daemon on :7456
# ---------------------------------------------------------------------------
resource "kubernetes_service_v1" "open_design" {
  depends_on = [kubernetes_deployment_v1.open_design]

  metadata {
    name      = "open-design"
    namespace = local.od_ns
    labels    = local.od_labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.od_labels
    port {
      port        = 80
      target_port = local.od_web_port
      name        = "http"
    }
  }
}

# ---------------------------------------------------------------------------
# HTTPRoute — expose via main-gateway (Gateway API)
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "open_design_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.open_design]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "open-design", namespace = local.od_ns }
    spec = {
      hostnames = [local.od_host]
      parentRefs = [{
        group       = "gateway.networking.k8s.io"
        kind        = "Gateway"
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "http"
      }]
      rules = [{
        matches = [{
          path = { type = "PathPrefix", value = "/" }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          group  = ""
          kind   = "Service"
          name   = "open-design"
          port   = 80
          weight = 1
        }]
      }]
    }
  }
}