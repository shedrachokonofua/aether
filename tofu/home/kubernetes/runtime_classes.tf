# =============================================================================
# RuntimeClasses
# =============================================================================
# Platform-owned runtime handlers registered by Talos system extensions.

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
