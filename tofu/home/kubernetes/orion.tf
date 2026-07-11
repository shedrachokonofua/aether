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
  orion_ns            = module.namespace["orion"].name
  orion_labels        = { app = "orion" }
  orion_registry_host = "registry.gitlab.home.shdr.ch"
  orion_registry_user = var.secrets["gitlab.root_email"]
  orion_registry_pass = var.secrets["gitlab.root_password"]
}

# Pull secret for the private GitLab registry (same creds as composer/open-design).
resource "kubernetes_secret_v1" "orion_gitlab_registry" {
  depends_on = [module.namespace["orion"]]

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
locals {
  orion_env = {
    OIDC_ISSUER          = "https://auth.shdr.ch/realms/aether"
    OIDC_CLIENT_ID       = "orion"
    OIDC_CLIENT_SECRET   = var.orion_oauth_client_secret
    OIDC_REDIRECT_URI    = "https://${local.orion_host}/auth/callback"
    OIDC_SCOPE           = "openid profile email"
    SESSION_SECRET       = random_password.orion_session_secret.result
    SQLITE_DATABASE_PATH = "/data/orion.sqlite"
    # News widget → self-hosted Miniflux (API key minted in Miniflux, stored in SOPS).
    MINIFLUX_URL     = "https://miniflux.home.shdr.ch"
    MINIFLUX_API_KEY = var.secrets["miniflux.orion_api_key"]
    # LLM + web search → LiteLLM and SearXNG over cluster DNS (hairpin via the
    # LAN Caddy VM removed per namespace-strategy §8.2 / answer-engine Slice 13).
    LITELLM_URL     = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
    LITELLM_API_KEY = var.secrets["litellm.virtual_keys.orion"]
    SEARXNG_URL     = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.searxng_ns}.svc.cluster.local:${local.searxng_port}"
    # Answer engine (orion docs/plans/answer-engine.md): one resident chat
    # model for every pipeline call, and Firecrawl for page extraction.
    ANSWER_MODEL      = "aether/qwen3.6-27b"
    FIRECRAWL_URL     = "http://${kubernetes_service_v1.firecrawl.metadata[0].name}.${local.firecrawl_ns}.svc.cluster.local:${local.firecrawl_api_port}"
    FIRECRAWL_API_KEY = var.secrets["firecrawl.api_key"]
    # Metrics + service discovery → Prometheus (same instance Grafana uses).
    PROMETHEUS_URL = "https://prometheus.home.shdr.ch"
    # Search "Ask Beryl" → the Hermes Beryl agent's OpenAI-compatible API
    # (in-cluster; key is the same random_password Hermes uses for its api_server).
    BERYL_API_URL = "http://hermes-beryl.hermes.svc.cluster.local:8642/v1"
    BERYL_API_KEY = random_password.hermes_api_server_key["beryl"].result
  }
}

resource "kubernetes_secret_v1" "orion_env" {
  depends_on = [module.namespace["orion"]]

  metadata {
    name      = "orion-env"
    namespace = local.orion_ns
  }

  data = local.orion_env

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "orion_data" {
  depends_on = [module.namespace["orion"], kubernetes_storage_class_v1.ceph_rbd]

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
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = local.orion_labels
    }

    template {
      metadata {
        labels = local.orion_labels
        annotations = {
          # Roll the pod when the env secret changes — env_from alone does not
          # restart the container, and keel only reacts to image digests.
          "aether.shdr.ch/env-checksum" = nonsensitive(sha256(jsonencode(local.orion_env)))
        }
      }

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

  lifecycle {
    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
      spec[0].template[0].spec[0].priority_class_name,
      # Keel force-updates rewrite these on a new :latest digest; tofu must not revert them.
      metadata[0].annotations["kubernetes.io/change-cause"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
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

# Declared egress for the answer engine's in-cluster flows (orion → litellm,
# searxng, firecrawl). Additive-only: enableDefaultDeny=false mirrors the
# cluster-baseline pattern — these rules pre-authorize the flows for the
# namespace-strategy default-deny flip without changing behavior today.
resource "kubernetes_manifest" "orion_answer_egress" {
  depends_on = [helm_release.cilium, module.namespace["orion"]]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "orion-answer-egress"
      namespace = local.orion_ns
    }
    spec = {
      endpointSelector = {}
      enableDefaultDeny = {
        ingress = false
        egress  = false
      }
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.litellm_ns
            }
          }]
          toPorts = [{
            ports = [{ port = tostring(local.litellm_port), protocol = "TCP" }]
          }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.searxng_ns
            }
          }]
          toPorts = [{
            ports = [{ port = tostring(local.searxng_port), protocol = "TCP" }]
          }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.firecrawl_ns
            }
          }]
          toPorts = [{
            ports = [{ port = tostring(local.firecrawl_api_port), protocol = "TCP" }]
          }]
        },
      ]
    }
  }
}
