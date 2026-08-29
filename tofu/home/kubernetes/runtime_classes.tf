# =============================================================================
# RuntimeClasses
# =============================================================================
# Platform-owned runtime handlers registered by Talos system extensions.

# Only amd64 Talos nodes carry kata-containers; Pi schematics ship no kata
# extension, and Pi 5 kata remains unvalidated.

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
      }
    }
  }
}
