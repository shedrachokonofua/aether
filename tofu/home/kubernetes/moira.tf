# =============================================================================
# Moira — quota-aware router in front of LiteLLM
# =============================================================================
# Source: ssh://git@ssh.gitlab.home.shdr.ch:2222/so/moira.git
# One image, three modes. Two run here: `serve` (quota-decision API on
# POST /decide, called by the moira_router pre-call hook in litellm_hooks.py)
# and `poll` (quota poller). The third,
# `chatgpt-usage`, runs as a sidecar inside the LiteLLM pod (litellm.tf) so it
# can read the ChatGPT OAuth auth file from the litellm-chatgpt-auth PVC.
# Config contract: moira/tiers.yaml (static) + models.yaml (tofu projection of
# the LiteLLM model_list).

locals {
  # PENDING_CI_DIGEST: the GitLab CI image build publishes the real digest;
  # this sentinel is replaced with it before the first Moira apply.
  moira_image = "registry.gitlab.home.shdr.ch/so/moira@sha256:90c8b9c3891f192c25e49d4cf4d1a1801780d6613bb3d5f69ded71e600c98e43"

  moira_ns                  = local.litellm_ns
  moira_labels              = { app = "moira" }
  moira_poller_labels       = { app = "moira-poller" }
  moira_port                = 8080
  moira_poller_metrics_port = 9091
  moira_sidecar_port        = 9090
  moira_registry_host       = "registry.gitlab.home.shdr.ch"
  moira_registry_user       = var.secrets["gitlab.root_email"]
  moira_registry_pass       = var.secrets["gitlab.root_password"]

  # models.yaml: projection of the LiteLLM model_list per the Moira contract
  # ({name, upstream, credential, info}). The projection keeps only model
  # names/upstreams/credential names and capability info — no secret material —
  # so it is lifted out of the sensitive templatefile value for the
  # non-secret ConfigMap.
  moira_models = nonsensitive([
    for m in yamldecode(local.litellm_config_yaml).model_list : {
      name       = m.model_name
      upstream   = m.litellm_params.model
      credential = try(m.litellm_params.litellm_credential_name, null)
      info       = try(m.model_info, {})
    }
  ])

  moira_model_names = [for m in local.moira_models : m.name]
  moira_tiers       = yamldecode(file("${path.module}/moira/tiers.yaml"))
}

resource "random_password" "moira_db_password" {
  length  = 32
  special = false
}

resource "random_password" "moira_sidecar_token" {
  length  = 48
  special = false
}

resource "random_password" "moira_decide_token" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "moira_registry" {
  depends_on = [module.namespace["litellm"]]

  metadata {
    name      = "moira-registry"
    namespace = local.moira_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.moira_registry_host) = {
          username = local.moira_registry_user
          password = local.moira_registry_pass
          auth     = base64encode("${local.moira_registry_user}:${local.moira_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "moira_env" {
  depends_on = [module.namespace["litellm"]]

  metadata {
    name      = "moira-env"
    namespace = local.moira_ns
  }

  data = {
    MOIRA_DATABASE_URL = "postgres://moira:${random_password.moira_db_password.result}@${local.litellm_db_host}:5432/moira?sslmode=disable"
    # Same role on the litellm database; it holds only pg_read_all_data there.
    LITELLM_DATABASE_URL = "postgres://moira:${random_password.moira_db_password.result}@${local.litellm_db_host}:5432/litellm?sslmode=disable"
    MOIRA_SIDECAR_TOKEN  = random_password.moira_sidecar_token.result
    # Bearer token for POST /decide, shared with the LiteLLM moira_router hook.
    MOIRA_DECIDE_TOKEN = random_password.moira_decide_token.result
  }

  type = "Opaque"
}

# Consumed by the litellm-cnpg Cluster's managed.roles block and the moira-db
# Database manifest in cnpg_adopted.tf.
resource "kubernetes_secret_v1" "moira_db_credentials" {
  depends_on = [module.namespace["litellm"]]

  metadata {
    name      = "moira-db-credentials"
    namespace = local.moira_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = "moira"
    password = random_password.moira_db_password.result
  }
}

resource "kubernetes_config_map_v1" "moira" {
  depends_on = [module.namespace["litellm"]]

  metadata {
    name      = "moira-config"
    namespace = local.moira_ns
  }

  data = {
    "models.yaml" = yamlencode({ models = local.moira_models })
    "tiers.yaml"  = file("${path.module}/moira/tiers.yaml")
  }
}

resource "kubernetes_deployment_v1" "moira" {
  depends_on = [
    kubernetes_config_map_v1.moira,
    kubernetes_secret_v1.moira_env,
    kubernetes_secret_v1.moira_registry,
  ]

  wait_for_rollout = false

  metadata {
    name      = "moira"
    namespace = local.moira_ns
    labels    = local.moira_labels
  }

  spec {
    replicas = 2

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }

    selector {
      match_labels = local.moira_labels
    }

    template {
      metadata {
        labels = local.moira_labels
        annotations = {
          "aether.shdr.ch/moira-image" = local.moira_image
          "aether.shdr.ch/config-sha"  = sha256(jsonencode(kubernetes_config_map_v1.moira.data))
          "aether.shdr.ch/env-sha"     = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.moira_env.data)))
        }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false
        node_selector                   = { "kubernetes.io/arch" = "amd64" }

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.moira_registry.metadata[0].name
        }

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_labels = local.moira_labels
                }
              }
            }
          }
        }

        container {
          name              = "moira"
          image             = local.moira_image
          image_pull_policy = "IfNotPresent"
          args              = ["serve"]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "MOIRA_CONFIG_DIR"
            value = "/etc/moira"
          }

          env {
            name  = "PORT"
            value = tostring(local.moira_port)
          }

          env {
            name = "MOIRA_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.moira_env.metadata[0].name
                key  = "MOIRA_DATABASE_URL"
              }
            }
          }

          env {
            name = "MOIRA_DECIDE_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.moira_env.metadata[0].name
                key  = "MOIRA_DECIDE_TOKEN"
              }
            }
          }

          port {
            container_port = local.moira_port
            name           = "http"
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = local.moira_port
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.moira_port
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          resources {
            requests = { cpu = "50m", memory = "96Mi" }
            limits   = { cpu = "1", memory = "384Mi" }
          }

          volume_mount {
            name       = "moira-config"
            mount_path = "/etc/moira"
            read_only  = true
          }
        }

        volume {
          name = "moira-config"
          config_map {
            name = kubernetes_config_map_v1.moira.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition = alltrue([
        for members in values(local.moira_tiers.groups) :
        alltrue([for m in members : contains(local.moira_model_names, m)])
      ])
      error_message = "tiers.yaml groups reference model names missing from the LiteLLM model_list projection (moira-config models.yaml)."
    }

    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_pod_disruption_budget_v1" "moira" {
  depends_on = [kubernetes_deployment_v1.moira]

  metadata {
    name      = "moira"
    namespace = local.moira_ns
    labels    = local.moira_labels
  }

  spec {
    min_available = 1

    selector {
      match_labels = local.moira_labels
    }
  }
}

resource "kubernetes_deployment_v1" "moira_poller" {
  depends_on = [
    kubernetes_config_map_v1.moira,
    kubernetes_secret_v1.moira_env,
    kubernetes_secret_v1.moira_registry,
    kubernetes_secret_v1.litellm_env,
  ]

  wait_for_rollout = false

  metadata {
    name      = "moira-poller"
    namespace = local.moira_ns
    labels    = local.moira_poller_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.moira_poller_labels
    }

    template {
      metadata {
        labels = local.moira_poller_labels
        annotations = {
          "aether.shdr.ch/moira-image" = local.moira_image
          "aether.shdr.ch/config-sha"  = sha256(jsonencode(kubernetes_config_map_v1.moira.data))
          "aether.shdr.ch/env-sha"     = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.moira_env.data)))
        }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false
        node_selector                   = { "kubernetes.io/arch" = "amd64" }

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.moira_registry.metadata[0].name
        }

        container {
          name              = "moira-poller"
          image             = local.moira_image
          image_pull_policy = "IfNotPresent"
          args              = ["poll"]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          env {
            name  = "MOIRA_CONFIG_DIR"
            value = "/etc/moira"
          }

          env {
            name  = "PORT"
            value = tostring(local.moira_port)
          }

          env {
            name  = "POLL_METRICS_PORT"
            value = tostring(local.moira_poller_metrics_port)
          }

          env {
            name = "MOIRA_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.moira_env.metadata[0].name
                key  = "MOIRA_DATABASE_URL"
              }
            }
          }

          env {
            name = "LITELLM_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.moira_env.metadata[0].name
                key  = "LITELLM_DATABASE_URL"
              }
            }
          }

          env {
            name = "MOIRA_SIDECAR_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.moira_env.metadata[0].name
                key  = "MOIRA_SIDECAR_TOKEN"
              }
            }
          }

          env {
            name = "ZAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ZAI_API_KEY"
              }
            }
          }

          env {
            name = "KIMI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "KIMI_API_KEY"
              }
            }
          }

          env {
            name = "COMMANDCODE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "COMMANDCODE_API_KEY"
              }
            }
          }

          env {
            name = "OPENCODE_GO_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OPENCODE_GO_API_KEY"
              }
            }
          }

          env {
            name = "CLINEPASS_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "CLINEPASS_API_KEY"
              }
            }
          }

          env {
            name = "OLLAMA_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "OLLAMA_API_KEY"
              }
            }
          }

          env {
            name = "GROK_BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "GROK_BRIDGE_API_KEY"
              }
            }
          }

          env {
            name = "ANTIGRAVITY_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "ANTIGRAVITY_API_KEY"
              }
            }
          }

          env {
            name = "MUSE_BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "MUSE_BRIDGE_API_KEY"
              }
            }
          }

          env {
            name = "CLAUDE_BRIDGE_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_env.metadata[0].name
                key  = "CLAUDE_BRIDGE_API_KEY"
              }
            }
          }

          port {
            container_port = local.moira_poller_metrics_port
            name           = "metrics"
          }

          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          volume_mount {
            name       = "moira-config"
            mount_path = "/etc/moira"
            read_only  = true
          }
        }

        volume {
          name = "moira-config"
          config_map {
            name = kubernetes_config_map_v1.moira.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting.
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_service_v1" "moira" {
  depends_on = [kubernetes_deployment_v1.moira]

  metadata {
    name      = "moira"
    namespace = local.moira_ns
    labels    = local.moira_labels
  }

  spec {
    selector = local.moira_labels

    port {
      port        = local.moira_port
      target_port = local.moira_port
      name        = "http"
    }
  }
}

# Exposed on the repo's named "metrics" port convention (jellyfin-exporter,
# matrix) for the otel-collector scrape jobs; add a scrape job in
# otel_collector.tf to actually collect it.
resource "kubernetes_service_v1" "moira_poller_metrics" {
  depends_on = [kubernetes_deployment_v1.moira_poller]

  metadata {
    name      = "moira-poller-metrics"
    namespace = local.moira_ns
    labels    = local.moira_poller_labels
  }

  spec {
    selector = local.moira_poller_labels

    port {
      port        = local.moira_poller_metrics_port
      target_port = local.moira_poller_metrics_port
      name        = "metrics"
    }
  }
}

# The litellm namespace declares egress = "allowlist", and the poller is the
# only Moira workload with outbound calls: quota endpoints (kind endpoint),
# in-cluster bridges (kind bridge), the ChatGPT usage sidecar behind the
# litellm Service (:9090), and the CNPG databases. Local-plan providers are
# counted from the LiteLLM spend log (DB) and make no direct calls.
resource "kubernetes_manifest" "moira_poller_egress" {
  depends_on = [helm_release.cilium, kubernetes_deployment_v1.moira_poller]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "moira-poller-egress"
      namespace = local.moira_ns
    }
    spec = {
      endpointSelector = { matchLabels = local.moira_poller_labels }
      enableDefaultDeny = {
        egress  = true
        ingress = false
      }
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "k8s-app"                     = "kube-dns"
              "io.kubernetes.pod.namespace" = "kube-system"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
            rules = { dns = [{ matchPattern = "*" }] }
          }]
        },
        {
          toFQDNs = [
            { matchName = "api.z.ai" },
            { matchName = "api.kimi.com" },
            { matchName = "api.commandcode.ai" },
            { matchName = "opencode.ai" },
            { matchName = "api.cline.bot" },
            { matchName = "ollama.com" },
          ]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "app"                         = "grok-bridge"
              "io.kubernetes.pod.namespace" = local.grok_ns
            }
          }]
          toPorts = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "app"                         = "antigravity-bridge"
              "io.kubernetes.pod.namespace" = local.antigravity_ns
            }
          }]
          toPorts = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "app"                         = "muse-bridge"
              "io.kubernetes.pod.namespace" = local.muse_ns
            }
          }]
          toPorts = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "app"                         = "claude-bridge"
              "io.kubernetes.pod.namespace" = local.claude_ns
            }
          }]
          toPorts = [{ ports = [{ port = tostring(local.claude_port), protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "app"                         = "litellm"
              "io.kubernetes.pod.namespace" = local.litellm_ns
            }
          }]
          toPorts = [{
            ports = [{ port = "9090", protocol = "TCP" }]
          }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "cnpg.io/cluster"             = local.litellm_cnpg_cluster
              "io.kubernetes.pod.namespace" = local.litellm_ns
            }
          }]
          toPorts = [{ ports = [{ port = "5432", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
