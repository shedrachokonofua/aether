# =============================================================================
# HolyClaude — Pre-configured AI Coding Environment
# =============================================================================
# Pre-configured container with Claude Code CLI, CloudCLI web UI, headless
# Chromium, and dozens of developer tools.
#
# Runs in Kata Containers for safe nested virtualization / sandboxing.
# =============================================================================


locals {
  holyclaude_image  = "coderluii/holyclaude:latest"
  holyclaude_host   = "holyclaude.home.shdr.ch"
  holyclaude_port   = 3001
  holyclaude_ns     = module.namespace["holyclaude"].name
  holyclaude_labels = { app = "holyclaude" }
}

# -----------------------------------------------------------------------------
# Storage — Credentials and Session State
# -----------------------------------------------------------------------------
resource "kubernetes_persistent_volume_claim_v1" "holyclaude_config" {
  depends_on = [module.namespace["holyclaude"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "holyclaude-config"
    namespace = local.holyclaude_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Storage — Workspace for Agent Workflows
# -----------------------------------------------------------------------------
resource "kubernetes_persistent_volume_claim_v1" "holyclaude_workspace" {
  depends_on = [module.namespace["holyclaude"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "holyclaude-workspace"
    namespace = local.holyclaude_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Deployment
# -----------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "holyclaude" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.holyclaude_config,
    kubernetes_persistent_volume_claim_v1.holyclaude_workspace
  ]

  metadata {
    name      = "holyclaude"
    namespace = local.holyclaude_ns
    labels    = local.holyclaude_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.holyclaude_labels
    }

    template {
      metadata {
        labels = local.holyclaude_labels
      }

      spec {
        # Secure isolation boundary for running privileged/nested sandboxes
        runtime_class_name = "kata"
        node_selector      = { "kubernetes.io/arch" = "amd64" }

        enable_service_links = false

        container {
          name  = "holyclaude"
          image = local.holyclaude_image

          port {
            container_port = local.holyclaude_port
            name           = "http"
          }

          env {
            name  = "TZ"
            value = "UTC"
          }

          # Capabilities and Seccomp Profile required for Chromium sandboxing
          security_context {
            capabilities {
              add = ["SYS_ADMIN", "SYS_PTRACE"]
            }
            seccomp_profile {
              type = "Unconfined"
            }
          }

          # Resource limits matching full image requirements (boosted for Kata Containers hypervisor allocations)
          resources {
            requests = {
              cpu    = "2"
              memory = "4Gi"
            }
            limits = {
              cpu    = "6"
              memory = "8Gi"
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/home/claude/.claude"
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.holyclaude_port
            }
            initial_delay_seconds = 15
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/"
              port = local.holyclaude_port
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.holyclaude_config.metadata[0].name
          }
        }

        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.holyclaude_workspace.metadata[0].name
          }
        }

        # Memory volume representing shm_size = 2g
        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = "2Gi"
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

# -----------------------------------------------------------------------------
# Service
# -----------------------------------------------------------------------------
resource "kubernetes_service_v1" "holyclaude" {
  metadata {
    name      = "holyclaude"
    namespace = local.holyclaude_ns
    labels    = local.holyclaude_labels
  }

  spec {
    selector = local.holyclaude_labels
    port {
      port        = local.holyclaude_port
      target_port = local.holyclaude_port
      name        = "http"
    }
  }
}

# -----------------------------------------------------------------------------
# Gateway Routing (HTTPRoute)
# -----------------------------------------------------------------------------
resource "kubernetes_manifest" "holyclaude_route" {
  depends_on = [
    kubernetes_manifest.main_gateway,
    kubernetes_service_v1.holyclaude
  ]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "holyclaude"
      namespace = local.holyclaude_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.holyclaude_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.holyclaude.metadata[0].name
          port = local.holyclaude_port
        }]
      }]
    }
  }
}
