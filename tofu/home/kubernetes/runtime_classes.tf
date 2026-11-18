# =============================================================================
# RuntimeClasses
# =============================================================================
# Platform-owned runtime handlers registered by Talos system extensions.

# Only amd64 Talos VM nodes carry kata-containers; Pi schematics ship no kata
# extension, and Pi 5 kata remains unvalidated. aether.sh/kata is set by
# kubernetes_labels.talos_node_kata (talos_cluster.tf); talos-neo opts out.

resource "kubernetes_manifest" "kata_runtime_class" {
  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name = "kata"
    }
    handler = "kata"
    scheduling = {
      nodeSelector = {
        "kubernetes.io/arch" = "amd64"
        "aether.sh/kata"     = "true"
      }
    }
  }
}

# Kata with guest memory reclaim (tofu/home/kata/configuration-reclaim.toml):
# the same Kata, but a VM returns memory to the node. Daimyo's task pods and
# sandboxes run on it (daimyo.tf launcher.runtimeClass) since Kata VMs filled
# talos-trinity on 2026-11-18. aether.sh/kata-reclaim is set by
# kubernetes_labels.talos_node_kata_reclaim on every node carrying the handler.
resource "kubernetes_manifest" "kata_reclaim_runtime_class" {
  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name = "kata-reclaim"
    }
    handler = "kata-reclaim"
    scheduling = {
      nodeSelector = {
        "kubernetes.io/arch"     = "amd64"
        "aether.sh/kata-reclaim" = "true"
      }
    }
  }
}
