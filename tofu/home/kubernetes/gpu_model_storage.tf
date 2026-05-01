# =============================================================================
# GPU Model Storage — Local PV pinned to talos-neo
# =============================================================================
# A 500Gi static local-PV backed by /var/mnt/gpu-storage on talos-neo (the
# GPU node). Exposed to workloads through a single shared PVC; ComfyUI and
# (future) llama-swap mount sub-paths so model weights and runtime state sit
# on local NVMe instead of Ceph RBD.
#
# Layout under the PV root:
#   /comfyui/root/        ComfyUI state
#   /docling/models/      Docling artifacts cache (layout/OCR/VLM weights)
#   /llama-swap/models/   GGUF cache (migration TBD)

locals {
  gpu_local_sc_name      = "talos-neo-local"
  gpu_model_storage_pv   = "gpu-model-storage"
  gpu_model_storage_pvc  = "gpu-model-storage"
  gpu_model_storage_size = "500Gi"
  gpu_model_storage_path = "/var/mnt/gpu-storage"
  gpu_model_storage_node = "talos-neo"
  gpu_model_storage_ns   = kubernetes_namespace_v1.infra.metadata[0].name
}

# =============================================================================
# StorageClass — no-provisioner with WaitForFirstConsumer binding
# =============================================================================
# WaitForFirstConsumer ensures binding only happens once a Pod that can
# actually schedule on talos-neo references the PVC. Otherwise the PVC could
# bind to a PV whose nodeAffinity blocks every running Pod.

resource "kubernetes_storage_class_v1" "talos_neo_local" {
  metadata {
    name = local.gpu_local_sc_name
  }

  storage_provisioner = "kubernetes.io/no-provisioner"
  reclaim_policy      = "Retain"
  volume_binding_mode = "WaitForFirstConsumer"
}

# =============================================================================
# PV — talos-neo local disk
# =============================================================================

resource "kubernetes_persistent_volume_v1" "gpu_model_storage" {
  depends_on = [kubernetes_storage_class_v1.talos_neo_local]

  metadata {
    name = local.gpu_model_storage_pv
  }

  spec {
    capacity = { storage = local.gpu_model_storage_size }

    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.talos_neo_local.metadata[0].name

    persistent_volume_source {
      local {
        path = local.gpu_model_storage_path
      }
    }

    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [local.gpu_model_storage_node]
          }
        }
      }
    }
  }
}

# =============================================================================
# PVC — bound to the static PV
# =============================================================================

resource "kubernetes_persistent_volume_claim_v1" "gpu_model_storage" {
  depends_on = [
    kubernetes_namespace_v1.infra,
    kubernetes_persistent_volume_v1.gpu_model_storage,
  ]

  metadata {
    name      = local.gpu_model_storage_pvc
    namespace = local.gpu_model_storage_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.talos_neo_local.metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.gpu_model_storage.metadata[0].name

    resources {
      requests = { storage = local.gpu_model_storage_size }
    }
  }
}
