# =============================================================================
# Orion — personal AI dashboard / start page (home.shdr.ch)
# =============================================================================
# SvelteKit (adapter-node) + better-sqlite3. Image is autobuilt by GitLab CI
# from the orion repo and pushed to registry.gitlab.home.shdr.ch/so/orion/main.
# SQLite (sessions + users) lives on a small RBD PVC at /data.
# Auth is real Keycloak OIDC (realm: aether, client: orion) — no bypass in prod.
#
# Apex host home.shdr.ch is routed via a dedicated main-gateway listener
# ("home-root" in gateway.tf) since the *.home.shdr.ch wildcard does not match
# the bare apex.

locals {
  orion_image         = "registry.gitlab.home.shdr.ch/so/orion/main:latest"
  orion_host          = "home.shdr.ch"
  orion_port          = 3000
  orion_ns            = kubernetes_namespace_v1.personal.metadata[0].name
  orion_labels        = { app = "orion" }
  orion_registry_host = "registry.gitlab.home.shdr.ch"
  orion_registry_user = var.secrets["gitlab.root_email"]
  orion_registry_pass = var.secrets["gitlab.root_password"]
}

# Pull secret for the private GitLab registry (same creds as composer/open-design).
resource "kubernetes_secret_v1" "orion_gitlab_registry" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "orion-gitlab-registry"
    namespace = local.orion_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.orion_registry_host) = {
          username = local.orion_registry_user
          password = local.orion_registry_pass
          auth     = base64encode("${local.orion_registry_user}:${local.orion_registry_pass}")
        }
      }
    })
  }
}

# Session signing key — generated and held in tofu state (like openwebui's
# postgres password). Rotating it invalidates active sessions, which is fine.
resource "random_password" "orion_session_secret" {
  length  = 48
  special = true
}

# Env vars sourced from tofu state + the OIDC client secret var. The OIDC
# client secret is passed down from the parent module (see talos_cluster.tf).
resource "kubernetes_secret_v1" "orion_env" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "orion-env"
    namespace = local.orion_ns
  }

  data = {
    OIDC_ISSUER          = "https://auth.shdr.ch/realms/aether"
    OIDC_CLIENT_ID       = "orion"
    OIDC_CLIENT_SECRET   = var.orion_oauth_client_secret
    OIDC_REDIRECT_URI    = "https://${local.orion_host}/auth/callback"
    OIDC_SCOPE           = "openid profile email"
    SESSION_SECRET       = random_password.orion_session_secret.result
    SQLITE_DATABASE_PATH = "/data/orion.sqlite"
    # News widget → self-hosted Miniflux (API key minted in Miniflux, stored in SOPS).
    MINIFLUX_URL     = "https://miniflux.home.shdr.ch"
    MINIFLUX_API_KEY = lookup(var.secrets, "miniflux.orion_api_key", "")
    # AI summary / search → self-hosted LiteLLM (dedicated orion virtual key in SOPS).
    LITELLM_URL     = "https://litellm.home.shdr.ch/v1"
    LITELLM_API_KEY = var.secrets["litellm.virtual_keys.orion"]
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "orion_data" {
  depends_on = [kubernetes_namespace_v1.personal, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "orion-data"
    namespace = local.orion_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources { requests = { storage = "1Gi" } }
  }
}

resource "kubernetes_deployment_v1" "orion" {
  depends_on = [
    kubernetes_persistent_volume_claim_v1.orion_data,
    kubernetes_secret_v1.orion_gitlab_registry,
    kubernetes_secret_v1.orion_env,
  ]

  wait_for_rollout = false

  metadata {
    name      = "orion"
    namespace = local.orion_ns
    labels    = local.orion_labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = local.orion_labels
    }

    template {
      metadata { labels = local.orion_labels }

      spec {
        enable_service_links = false

        image_pull_secrets {
          name = kubernetes_secret_v1.orion_gitlab_registry.metadata[0].name
        }

        container {
          name              = "orion"
          image             = local.orion_image
          image_pull_policy = "Always"

          env_from {
            secret_ref { name = kubernetes_secret_v1.orion_env.metadata[0].name }
          }

          port {
            container_port = local.orion_port
            name           = "http"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/login"
              port = local.orion_port
            }
            initial_delay_seconds = 5
            period_seconds        = 15
          }
        }

        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.orion_data.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "orion" {
  depends_on = [kubernetes_deployment_v1.orion]

  metadata {
    name      = "orion"
    namespace = local.orion_ns
    labels    = local.orion_labels
  }

  spec {
    selector = local.orion_labels
    port {
      port        = local.orion_port
      target_port = local.orion_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "orion_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.orion]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "orion", namespace = local.orion_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.orion_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "orion", port = local.orion_port }]
      }]
    }
  }
}