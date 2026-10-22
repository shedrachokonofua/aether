# =============================================================================
# Cicada — software factory server (sibling repo so/cicada)
# =============================================================================
# One distroless image (registry.gitlab.home.shdr.ch/so/cicada, built by CI on
# main): `/cicada serve` is the REST API, the web UI, the agents' MCP, the
# GitLab webhook and the reconciler. aether owns every cluster object. Keel
# stays off; roll out a verified digest through cicada_image.
#
# The ledger is a `cicada` database on daimyo's CNPG cluster (daimyo-pg), the
# same shape as moira-db on litellm-cnpg. Secrets are files under
# /etc/cicada/secrets (config.rs reads files, never inline secrets).

locals {
  # so/cicada main 7da103f, pipeline 7575 job build-image (image.digest).
  cicada_image = "registry.gitlab.home.shdr.ch/so/cicada@sha256:8a9bf34ff2bef8c255194ea5d437328a2a9427987f74957725b1213c06020532"

  cicada_ns            = module.namespace["cicada"].name
  cicada_host          = "cicada.home.shdr.ch"
  cicada_port          = 8080
  cicada_db_host       = "daimyo-pg-rw.daimyo-system.svc.cluster.local"
  cicada_registry_host = "registry.gitlab.home.shdr.ch"

  cicada_labels = {
    "app.kubernetes.io/name"       = "cicada"
    "app.kubernetes.io/part-of"    = "cicada"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
  # The whole toml, including the database URL (a literal connection string;
  # config.rs does not read it from a file or expand variables). It therefore
  # lives in the Secret, not a ConfigMap. Every *_file path is read by Cicada.
  cicada_config = <<-TOML
    database_url = "postgres://cicada:${random_password.cicada_db_password.result}@${local.cicada_db_host}:5432/cicada?sslmode=disable"
    listen = "0.0.0.0:${local.cicada_port}"

    [daimyo]
    url = "https://daimyo.home.shdr.ch"
    org = "cicada"
    token_url = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/token"
    client_id = "cicada"
    client_secret_file = "/etc/cicada/secrets/daimyo-client-secret"

    [gitlab]
    url = "https://gitlab.home.shdr.ch/"
    token_file = "/etc/cicada/secrets/gitlab-token"
    webhook_token_file = "/etc/cicada/secrets/gitlab-webhook-token"

    # Every repository's writers run in the one daimyo project `cicada`
    # (daimyo.tf daimyo_project), not a project per repository.
    [projects]
    "so/molecule" = "cicada"
    "so/turmeric" = "cicada"

    [agents]
    # As pods in cicada-tasks reach this Service.
    mcp_url = "http://cicada.cicada.svc.cluster.local:8080/mcp"

    [otel]
    endpoint = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318/v1/traces"

    [auth]
    issuer = "https://auth.shdr.ch/realms/aether"
    audience = "cicada"
    # shdrch signs in through cicada-operator; the automation client
    # (keycloak.tf cicada_automation) acts for the operator from scripts.
    operators = ["shdrch", "service-account-cicada-automation"]
    ui_client_id = "cicada-operator"
  TOML
}

# Operator-written, read at plan time the way colony.tf reads kv/colony/*.
# The kubernetes module cannot reference keycloak_openid_client.cicada (that
# resource lives in tofu/home, and threading a new module variable means
# editing main.tf and talos_cluster.tf, both of which have unrelated
# uncommitted changes). Before the first plan:
#   bao kv put kv/cicada/gitlab \
#     token="$(cat ~/.config/cicada/group-lander-token)" \
#     client_secret="$(tofu -chdir=tofu/home output -raw keycloak_cicada_client_secret)" \
#     webhook_token="$(cat ~/.config/cicada/gitlab-webhook-token)"
# `token` is the lander token: group access token cicada-lander on group `so`
# (api scope, Maintainer), so one token reaches every repository Cicada runs.
# The writers' git token is kv/orgs/cicada/gitlab `token`: group access token
# cicada-writer on `so` (read/write_repository, Developer); daimyo mints the
# writers' git grants from it.
# `webhook_token` is the secret of every Cicada repository's project hook
# (https://cicada.home.shdr.ch/hooks/gitlab; merge request, pipeline, push
# and note events: so/cicada hook 10, so/molecule, so/turmeric); GitLab sends
# it as X-Gitlab-Token.
data "vault_kv_secret_v2" "cicada_gitlab" {
  mount = "kv"
  name  = "cicada/gitlab"
}

resource "random_password" "cicada_db_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "cicada_registry" {
  depends_on = [module.namespace["cicada"]]

  metadata {
    name      = "cicada-registry"
    namespace = local.cicada_ns
    labels    = local.cicada_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.cicada_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

# basic-auth: CNPG managed.roles reads username/password (moira-db).
resource "kubernetes_secret_v1" "cicada_db_credentials" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "cicada-db-credentials"
    namespace = local.daimyo_ns
    labels    = local.cicada_labels
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = "cicada"
    password = random_password.cicada_db_password.result
  }
}

# cicada.toml plus the three files it names. One Secret so a config change
# and a token change roll the pod together (env-sha below).
resource "kubernetes_secret_v1" "cicada_secrets" {
  depends_on = [module.namespace["cicada"]]

  metadata {
    name      = "cicada-secrets"
    namespace = local.cicada_ns
    labels    = local.cicada_labels
  }

  type = "Opaque"

  data = {
    "cicada.toml"          = local.cicada_config
    "daimyo-client-secret" = data.vault_kv_secret_v2.cicada_gitlab.data["client_secret"]
    "gitlab-token"         = data.vault_kv_secret_v2.cicada_gitlab.data["token"]
    "gitlab-webhook-token" = data.vault_kv_secret_v2.cicada_gitlab.data["webhook_token"]
  }
}

# The chart owns daimyo-pg's `managed.roles` and Helm replaces that list, so
# adding the cicada login there would drop daimyo_api and daimyo_engine; and
# the cluster has no superuser Secret (superuser access is off). The role was
# created once on the primary over the local socket, with the password from
# Secret daimyo-system/cicada-db-credentials (rerun after rotating it):
#   P=$(kubectl get pods -n daimyo-system -l cnpg.io/cluster=daimyo-pg,cnpg.io/instanceRole=primary -o name)
#   PW=$(kubectl get secret -n daimyo-system cicada-db-credentials -o jsonpath='{.data.password}' | base64 -d)
#   kubectl exec -i -n daimyo-system "$P" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -v pw="$PW" <<'SQL'
#   SELECT format('CREATE ROLE cicada LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cicada') \gexec
#   SELECT format('ALTER ROLE cicada LOGIN PASSWORD %L', :'pw') \gexec
#   SQL
resource "kubectl_manifest" "cicada_db" {
  depends_on = [kubernetes_secret_v1.cicada_db_credentials]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Database"
    metadata = {
      name      = "cicada-db"
      namespace = local.daimyo_ns
    }
    spec = {
      name    = "cicada"
      owner   = "cicada"
      cluster = { name = "daimyo-pg" }
    }
  })
}

resource "kubernetes_deployment_v1" "cicada" {
  depends_on = [
    kubernetes_secret_v1.cicada_secrets,
    kubernetes_secret_v1.cicada_registry,
    kubectl_manifest.cicada_db,
  ]

  wait_for_rollout = false

  metadata {
    name      = "cicada"
    namespace = local.cicada_ns
    labels    = local.cicada_labels
    annotations = {
      # One replica, and a digest pin: a webhook lands on this process
      # (decision 42) and an unreviewed image must not roll it.
      "keel.sh/policy" = "never"
    }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.cicada_labels
    }

    template {
      metadata {
        labels = local.cicada_labels
        annotations = {
          "aether.shdr.ch/config-sha" = sha256(local.cicada_config)
          "aether.shdr.ch/env-sha"    = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.cicada_secrets.data)))
        }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false

        security_context {
          # distroless nonroot (Dockerfile).
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          seccomp_profile { type = "RuntimeDefault" }
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.cicada_registry.metadata[0].name
        }

        container {
          name              = "cicada"
          image             = local.cicada_image
          image_pull_policy = "IfNotPresent"
          args              = ["serve", "--config", "/etc/cicada/config/cicada.toml"]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          port {
            name           = "http"
            container_port = local.cicada_port
          }

          # /v1/status requires the operator token. /ui/config.json is the
          # public sign-in document and answers 200 once the process listens.
          readiness_probe {
            http_get {
              path = "/ui/config.json"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 10
            timeout_seconds       = 5
          }

          liveness_probe {
            tcp_socket {
              port = "http"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
            timeout_seconds       = 5
            failure_threshold     = 6
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/cicada/config"
            read_only  = true
          }


          volume_mount {
            name       = "secrets"
            mount_path = "/etc/cicada/secrets"
            read_only  = true
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.cicada_secrets.metadata[0].name
            items {
              key  = "cicada.toml"
              path = "cicada.toml"
            }
          }
        }

        volume {
          name = "secrets"
          secret {
            secret_name  = kubernetes_secret_v1.cicada_secrets.metadata[0].name
            default_mode = "0444"
            items {
              key  = "daimyo-client-secret"
              path = "daimyo-client-secret"
            }
            items {
              key  = "gitlab-token"
              path = "gitlab-token"
            }
            items {
              key  = "gitlab-webhook-token"
              path = "gitlab-webhook-token"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].priority_class_name,
    ]
  }
}

resource "kubernetes_service_v1" "cicada" {
  depends_on = [module.namespace["cicada"]]

  metadata {
    name      = "cicada"
    namespace = local.cicada_ns
    labels    = local.cicada_labels
  }

  spec {
    selector = local.cicada_labels

    port {
      name        = "http"
      port        = local.cicada_port
      target_port = "http"
    }
  }
}

# Caddy already sends *.home.shdr.ch at the gateway VIP; this is the
# in-cluster route, same shape as daimyo_route.
resource "kubernetes_manifest" "cicada_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.cicada]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "cicada"
      namespace = local.cicada_ns
      labels    = local.cicada_labels
    }
    spec = {
      parentRefs = [{
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "http"
      }]
      hostnames = [local.cicada_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.cicada.metadata[0].name
          port = local.cicada_port
        }]
      }]
    }
  }
}

# The cicada namespace is not default-deny (only task namespaces and the
# miniflux canary are). These two policies still matter: cicada-tasks is
# default-deny egress, and its allow is daimyo_tasks_egress; this is the
# matching ingress, plus the gateway.
resource "kubernetes_manifest" "cicada_ingress" {
  depends_on = [helm_release.cilium, kubernetes_deployment_v1.cicada]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "cicada-ingress"
      namespace = local.cicada_ns
      labels    = local.cicada_labels
    }
    spec = {
      endpointSelector = {
        matchLabels = { "app.kubernetes.io/name" = "cicada" }
      }
      ingress = [
        {
          # Gateway (Cilium entity) for https://cicada.home.shdr.ch.
          fromEntities = ["ingress"]
          toPorts      = [{ ports = [{ port = tostring(local.cicada_port), protocol = "TCP" }] }]
        },
        {
          # Writers in daimyo's cicada-tasks namespace, /mcp.
          fromEndpoints = [{
            matchLabels = { "io.kubernetes.pod.namespace" = "cicada-tasks" }
          }]
          toPorts = [{ ports = [{ port = tostring(local.cicada_port), protocol = "TCP" }] }]
        },
        {
          # Cluster collector scrape of /metrics (public; otel_collector.tf).
          fromEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = "observability"
              "app.kubernetes.io/name"      = "opentelemetry-collector"
              "app.kubernetes.io/instance"  = "otel-cluster"
              "component"                   = "standalone-collector"
            }
          }]
          toPorts = [{ ports = [{ port = tostring(local.cicada_port), protocol = "TCP" }] }]
        },
      ]
    }
  }
}
