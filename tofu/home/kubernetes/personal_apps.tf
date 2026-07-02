# =============================================================================
# Personal Apps — Shared Namespace
# =============================================================================
# Stateless and simple stateful personal apps: SnapOtter, BentoPDF, Memos,
# Perplexica (now Vane), Vaultwarden.
# Complex multi-service apps (Affine, Dawarich, Karakeep, Hoppscotch,
# Your-Spotify) each get their own namespace defined in their own file.

resource "kubernetes_namespace_v1" "personal" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "personal"
    labels = {
      "goldilocks.fairwinds.com/enabled" = "true"
    }
  }
}
