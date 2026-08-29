# =============================================================================
# instacart-mcp — Instacart shopping MCP server
# =============================================================================
# A persistent browser profile is required for the logged-in Instacart session.

locals {
  instacart_mcp_image         = "registry.gitlab.home.shdr.ch/so/instacart-mcp:latest"
  instacart_mcp_host          = "instacart-mcp.home.shdr.ch"
  instacart_mcp_port          = 8080
  instacart_mcp_ns            = module.namespace["instacart-mcp"].name
  instacart_mcp_labels        = { app = "instacart-mcp" }
  instacart_mcp_registry_host = "registry.gitlab.home.shdr.ch"
}

resource "kubernetes_secret_v1" "instacart_mcp_gitlab_registry" {
  depends_on = [module.namespace["instacart-mcp"]]

  metadata {
    name      = "instacart-mcp-gitlab-registry"
    namespace = local.instacart_mcp_ns
    labels    = local.instacart_mcp_labels
  }

  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.instacart_mcp_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

resource "kubernetes_persistent_volume_claim_v1" "instacart_mcp_profile" {
  depends_on = [
    module.namespace["instacart-mcp"],
    kubernetes_storage_class_v1.ceph_rbd,
  ]

  metadata {
    name      = "instacart-mcp-profile"
    namespace = local.instacart_mcp_ns
    labels    = local.instacart_mcp_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = local.cnpg_storage_class

    resources {
      requests = { storage = "2Gi" }
    }
  }
}

resource "kubernetes_deployment_v1" "instacart_mcp" {
  depends_on = [
    kubernetes_secret_v1.instacart_mcp_gitlab_registry,
    kubernetes_persistent_volume_claim_v1.instacart_mcp_profile,
  ]

  metadata {
    name      = "instacart-mcp"
    namespace = local.instacart_mcp_ns
    labels    = local.instacart_mcp_labels
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.instacart_mcp_labels
    }

    template {
      metadata {
        labels = local.instacart_mcp_labels
      }

      spec {
        enable_service_links = false
        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }

        # Non-root Chromium (uid 1000) must write the profile PVC.
        security_context {
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
          run_as_user            = 1000
          run_as_non_root        = true
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.instacart_mcp_gitlab_registry.metadata[0].name
        }

        container {
          name              = "instacart-mcp"
          image             = local.instacart_mcp_image
          image_pull_policy = "Always"

          port {
            container_port = local.instacart_mcp_port
            name           = "http"
          }

          env {
            name  = "MCP_TRANSPORT"
            value = "http"
          }
          env {
            name  = "MCP_PORT"
            value = tostring(local.instacart_mcp_port)
          }
          env {
            name  = "BROWSER_PROFILE_DIR"
            value = "/data/profile"
          }
          env {
            name  = "BROWSER_SESSION_FILE"
            value = "/data/session.json"
          }
          env {
            name  = "CACHE_DIR"
            value = "/data/cache"
          }
          env {
            name  = "HEADLESS"
            value = "false"
          }
          env {
            name  = "CHROME_BIN"
            value = "/usr/bin/chromium"
          }
          env {
            name  = "MNEMO_URL"
            value = "https://mnemo.home.shdr.ch"
          }
          env {
            name  = "INSTACART_EMAIL"
            value = "shedrachokonofua@gmail.com"
          }
          env {
            name  = "MNEMO_OTP_QUERY"
            value = "Instacart verification code"
          }
          env {
            name  = "CHROME_NO_SANDBOX"
            value = "1"
          }

          lifecycle {
            post_start {
              exec {
                command = [
                  "sh",
                  "-c",
                  "rm -f /data/profile/SingletonLock /data/profile/SingletonCookie /data/profile/SingletonSocket || true",
                ]
              }
            }
          }

          volume_mount {
            name       = "profile"
            mount_path = "/data"
          }

          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.instacart_mcp_port
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.instacart_mcp_port
            }
            initial_delay_seconds = 60
            timeout_seconds       = 5
            failure_threshold     = 6
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2"
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "profile"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.instacart_mcp_profile.metadata[0].name
          }
        }

        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Gi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting.
      spec[0].template[0].spec[0].priority_class_name,
      # Keel records force-update time on the pod template.
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }
}

resource "kubernetes_service_v1" "instacart_mcp" {
  depends_on = [kubernetes_deployment_v1.instacart_mcp]

  metadata {
    name      = "instacart-mcp"
    namespace = local.instacart_mcp_ns
    labels    = local.instacart_mcp_labels
  }

  spec {
    selector = local.instacart_mcp_labels

    port {
      port        = local.instacart_mcp_port
      target_port = local.instacart_mcp_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "instacart_mcp_route" {
  depends_on = [
    kubernetes_manifest.main_gateway,
    kubernetes_service_v1.instacart_mcp,
  ]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "instacart-mcp"
      namespace = local.instacart_mcp_ns
    }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.instacart_mcp_host]
      rules      = [{ backendRefs = [{ name = "instacart-mcp", port = local.instacart_mcp_port }] }]
    }
  }
}
