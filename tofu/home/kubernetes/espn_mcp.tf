# =============================================================================
# ESPN MCP Server
# =============================================================================
# Stateless MCP server exposing ESPN sports data.
# Serves Streamable HTTP on port 8080 (/mcp, /healthz).
# Image is built by GitLab CI and pushed to registry.gitlab.home.shdr.ch/so/espn-mcp.

locals {
  espn_mcp_image         = "registry.gitlab.home.shdr.ch/so/espn-mcp:latest"
  espn_mcp_host          = "espn-mcp.home.shdr.ch"
  espn_mcp_port          = 8080
  espn_mcp_ns            = module.namespace["espn-mcp"].name
  espn_mcp_labels        = { app = "espn-mcp" }
  espn_mcp_registry_host = "registry.gitlab.home.shdr.ch"
  espn_mcp_registry_user = var.secrets["gitlab.root_email"]
  espn_mcp_registry_pass = var.secrets["gitlab.root_password"]
}

resource "kubernetes_secret_v1" "espn_mcp_gitlab_registry" {
  depends_on = [module.namespace["espn-mcp"]]

  metadata {
    name      = "espn-mcp-gitlab-registry"
    namespace = local.espn_mcp_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.espn_mcp_registry_host) = {
          username = local.espn_mcp_registry_user
          password = local.espn_mcp_registry_pass
          auth     = base64encode("${local.espn_mcp_registry_user}:${local.espn_mcp_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_deployment_v1" "espn_mcp" {
  depends_on = [module.namespace["espn-mcp"], kubernetes_secret_v1.espn_mcp_gitlab_registry]

  metadata {
    name      = "espn-mcp"
    namespace = local.espn_mcp_ns
    labels    = local.espn_mcp_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.espn_mcp_labels
    }

    template {
      metadata {
        labels = local.espn_mcp_labels
      }

      spec {
        enable_service_links = false

        image_pull_secrets {
          name = kubernetes_secret_v1.espn_mcp_gitlab_registry.metadata[0].name
        }

        container {
          name  = "espn-mcp"
          image = local.espn_mcp_image

          # Start in HTTP mode on port 8080
          command = ["espn-mcp", "--http", "8080"]

          port {
            container_port = local.espn_mcp_port
            name           = "http"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.espn_mcp_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.espn_mcp_port
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "espn_mcp" {
  metadata {
    name      = "espn-mcp"
    namespace = local.espn_mcp_ns
    labels    = local.espn_mcp_labels
  }
  spec {
    selector = local.espn_mcp_labels
    port {
      port        = local.espn_mcp_port
      target_port = local.espn_mcp_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "espn_mcp_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.espn_mcp]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "espn-mcp", namespace = local.espn_mcp_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.espn_mcp_host]
      rules      = [{ backendRefs = [{ name = "espn-mcp", port = local.espn_mcp_port }] }]
    }
  }
}
