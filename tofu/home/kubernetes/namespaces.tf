# =============================================================================
# Shared Kubernetes Namespaces
# =============================================================================
# Namespaces that host more than one app live here. Per-app namespaces (e.g.
# nextcloud, immich) stay alongside their owning resources.

# `infra` — catch-all for cluster-internal services (docling, comfyui, jupyter,
# openwebui, litellm, llama-swap, searxng, ups-management, hermes, mux, etc.).
#
# Enrolled in the Istio Ambient mesh so ztunnel intercepts pod traffic
# transparently (L4 mTLS via SPIFFE). All services here are ClusterIP with no
# hostNetwork or NodePort, so interception is safe. Without the label, ztunnel
# sees zero traffic and `istio_tcp_connections_opened_total` stays empty.

resource "kubernetes_namespace_v1" "infra" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "infra"
    labels = {
      "goldilocks.fairwinds.com/enabled" = "true"
      "istio.io/dataplane-mode"          = "ambient"
    }
  }
}
