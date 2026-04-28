# =============================================================================
# JupyterLab — GPU Notebook Environment
# =============================================================================
# PyTorch + CUDA notebook for ML experimentation and OpenWebUI code execution.
# Uses upstream jupyter/pytorch-notebook image with no-auth config.

locals {
  jupyter_image  = "quay.io/jupyter/pytorch-notebook:cuda12-latest"
  jupyter_host   = "jupyter.home.shdr.ch"
  jupyter_port   = 8888
  jupyter_ns     = kubernetes_namespace_v1.infra.metadata[0].name
  jupyter_labels = { app = "jupyter" }
}

# =============================================================================
# PVC — Notebook Workspace (Ceph RBD)
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "jupyter_workspace" {
  depends_on = [kubernetes_namespace_v1.infra, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "jupyter-workspace"
    namespace = local.jupyter_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "20Gi" }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "jupyter" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubernetes_persistent_volume_claim_v1.jupyter_workspace,
  ]

  metadata {
    name      = "jupyter"
    namespace = local.jupyter_ns
    labels    = local.jupyter_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.jupyter_labels
    }

    template {
      metadata {
        labels = local.jupyter_labels
      }

      spec {
        runtime_class_name = "nvidia"

        node_selector = local.gpu_node_selector

        container {
          name  = "jupyter"
          image = local.jupyter_image
          args  = ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--ServerApp.token=", "--ServerApp.password=", "--ServerApp.allow_origin=*", "--ServerApp.allow_remote_access=True", "--ServerApp.disable_check_xsrf=True", "--ServerApp.trust_xheaders=True"]

          port {
            container_port = local.jupyter_port
            name           = "http"
          }

          env {
            name  = "JUPYTER_TOKEN"
            value = ""
          }

          env {
            name  = "NVIDIA_VISIBLE_DEVICES"
            value = "all"
          }

          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "compute,utility"
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/home/jovyan/work"
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
              path = "/api"
              port = local.jupyter_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/api"
              port = local.jupyter_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.jupyter_workspace.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "jupyter" {
  metadata {
    name      = "jupyter"
    namespace = local.jupyter_ns
    labels    = local.jupyter_labels
  }

  spec {
    selector = local.jupyter_labels

    port {
      port        = local.jupyter_port
      target_port = local.jupyter_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "jupyter_route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "jupyter"
      namespace = local.jupyter_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.jupyter_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.jupyter.metadata[0].name
          port = local.jupyter_port
        }]
      }]
    }
  }
}
