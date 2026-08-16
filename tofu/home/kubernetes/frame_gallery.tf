# =============================================================================
# frame-gallery — nightly generative art pipeline
#
# Sibling repo /Users/shdrch/projects/frame-gallery
# (ssh://git@ssh.gitlab.home.shdr.ch:2222/so/frame-gallery.git) owns the
# code, chart, and CI. Aether owns the namespace, secrets, deployment pin —
# the inquest/mnemo split.
# =============================================================================

locals {
  frame_gallery_chart_version = "0.1.0-7500b3a0" # Bump after sibling-repo publishes (chart version = 0.1.0-<commit sha>).
  frame_gallery_namespace     = module.namespace["frame-gallery"].name
}

# --- Secrets -----------------------------------------------------------------

resource "kubernetes_secret_v1" "frame_gallery_env" {
  depends_on = [module.namespace["frame-gallery"]]

  metadata {
    name      = "frame-gallery-env"
    namespace = local.frame_gallery_namespace
  }

  data = {
    IMMICH_API_KEY = var.secrets["immich.frame_api_key"]
    LITELLM_API_KEY = var.secrets["litellm.virtual_keys.frame_gallery"]
  }

  type = "Opaque"
}

# --- GitLab Registry Pull Secret --------------------------------------------

resource "kubernetes_secret_v1" "frame_gallery_registry" {
  depends_on = [module.namespace["frame-gallery"]]

  metadata {
    name      = "frame-gallery-gitlab-registry"
    namespace = local.frame_gallery_namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.gitlab_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

# --- Helm Release ------------------------------------------------------------

resource "helm_release" "frame_gallery" {
  depends_on = [
    kubernetes_secret_v1.frame_gallery_env,
    kubernetes_secret_v1.frame_gallery_registry,
    module.namespace["frame-gallery"],
  ]

  name       = "frame-gallery"
  repository = "oci://registry.gitlab.home.shdr.ch/so/frame-gallery"
  chart      = "frame-gallery"
  version    = local.frame_gallery_chart_version
  namespace  = local.frame_gallery_namespace
  wait       = true
  atomic     = true
  timeout    = 900

  values = [yamlencode({
    existingSecret = kubernetes_secret_v1.frame_gallery_env.metadata[0].name
    imagePullSecrets = [{
      name = kubernetes_secret_v1.frame_gallery_registry.metadata[0].name
    }]
    env = {
      # Pixoo output deliberately off — art lands only in Immich for the
      # Smart Frame. Flip here (not in the chart) if that changes.
      PIXOO_ENABLED = "false"
    }
  })]
}
