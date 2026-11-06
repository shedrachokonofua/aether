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
