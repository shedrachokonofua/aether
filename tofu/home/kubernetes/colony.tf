# =============================================================================
# Colony — colonyd control plane (sibling repo so/colony)
# =============================================================================
# Colony ships only a container image (registry.gitlab.home.shdr.ch/so/colony/
# colonyd, :latest on main, agent config baked into the image); aether owns
# every cluster object, following the orion/composer pattern. Keel force-polls
# :latest so a green colony main branch redeploys itself.
#
# Migrated 2026-08-16 from colony's own tofu module (so/colony tofu/ +
# GitLab-managed state "colony", both retired). Runtime secrets stay at
# kv/colony/* in OpenBao, read at plan time like colony's module did.

data "vault_kv_secret_v2" "colony_gitlab" {
  mount = "kv"
  name  = "colony/gitlab"
}

data "vault_kv_secret_v2" "colony_litellm" {
  mount = "kv"
  name  = "colony/litellm"
}

locals {
  colony_ns                    = module.namespace["colony"].name
  colony_image                 = "registry.gitlab.home.shdr.ch/so/colony/colonyd@sha256:58305e119f2bf52c15ebfa3345ff096e5364d846512d6acf58d457740061ee61"
  colony_drain_timeout_seconds = 600
  colony_host                  = "colony.home.shdr.ch"

  colony_labels = {
    "app.kubernetes.io/part-of"    = "colony"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
  colonyd_labels = merge(local.colony_labels, {
    "app.kubernetes.io/name"      = "colonyd"
    "app.kubernetes.io/component" = "colonyd"
  })

  colony_gitlab_env = data.vault_kv_secret_v2.colony_gitlab.data

  colony_env = {
    NODE_ENV = "production"
    # Bun's fetch ignores @kubernetes/client-node's undici CA dispatcher; trust
    # the in-cluster CA process-wide so sandbox provisioning can reach the API.
    NODE_EXTRA_CA_CERTS = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

    AGENT_RUNTIME = "pi"
    # Baked into the image by colony CI (config/colony.deploy.yaml).
    COLONY_CONFIG_PATH               = "/workspace/config/colony.deploy.yaml"
    COLONY_OPENAI_COMPATIBLE_API_KEY = data.vault_kv_secret_v2.colony_litellm.data["COLONY_OPENAI_COMPATIBLE_API_KEY"]
    COLONY_SEARXNG_URL               = "https://search.home.shdr.ch"

    GITLAB_BASE_URL       = lookup(local.colony_gitlab_env, "GITLAB_BASE_URL", "https://gitlab.home.shdr.ch")
    GITLAB_TOKEN          = lookup(local.colony_gitlab_env, "GITLAB_TOKEN", lookup(local.colony_gitlab_env, "GITLAB_BOT_ENGINE_TOKEN", ""))
    GITLAB_WEBHOOK_SECRET = lookup(local.colony_gitlab_env, "GITLAB_WEBHOOK_SECRET", "")

    PUBLIC_HOST = local.colony_host
    HOST        = "0.0.0.0"

    COLONYD_PORT    = "4400"
    COLONYD_DB_PATH = "/var/lib/colonyd/colonyd.db"
    COLONYD_TICK_MS = "15000"
    # Eight developer sandboxes saturate the namespace quota's limits
    # dimension (16 CPU / 32 GiB at 2/4Gi limits each) and the four kata
    # nodes' real headroom; dispatching past 8 burns 5-minute CR waits.
    COLONYD_MAX_CONCURRENT  = "8"
    COLONYD_MAX_ATTEMPTS    = "3"
    COLONY_DRAIN_TIMEOUT_MS = tostring(local.colony_drain_timeout_seconds * 1000)

    COLONY_METRICS_PORT = "9464"
    COLONY_OIDC_ISSUER  = "https://auth.shdr.ch/realms/aether"
    # Client declared in tofu/home/keycloak.tf (keycloak_openid_client.colony).
    COLONY_OIDC_CLIENT_ID     = "colony"
    COLONY_OIDC_REQUIRED_ROLE = "admin"

    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318/v1/metrics"
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318/v1/traces"
    # Full HTTP sampling: control-plane volume is one operator, not a fleet.
    COLONY_TRACE_HTTP_RATIO = "1"
    # Grafana Explore deep link into the Tempo datasource (resolved by name,
    # which works in any org); the console substitutes {trace_id} (hex,
    # encoding-stable) into the panes JSON.
    COLONY_TRACE_UI_BASE_URL = "https://grafana.home.shdr.ch/explore?schemaVersion=1&panes=%7B%22t%22%3A%7B%22datasource%22%3A%22Tempo%22%2C%22queries%22%3A%5B%7B%22query%22%3A%22{trace_id}%22%2C%22queryType%22%3A%22traceql%22%2C%22refId%22%3A%22A%22%7D%5D%7D%7D&orgId=1"

    HOME   = "/tmp"
    TMPDIR = "/tmp"
  }
}

resource "kubernetes_secret_v1" "colony_app_env" {
  depends_on = [module.namespace["colony"]]

  metadata {
    name      = "colony-app-env"
    namespace = local.colony_ns
    labels    = local.colony_labels
  }

  data = local.colony_env
  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "colonyd_data" {
  depends_on = [module.namespace["colony"]]

  metadata {
    name      = "colonyd-data"
    namespace = local.colony_ns
    labels    = local.colonyd_labels
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_service_account_v1" "colonyd" {
  depends_on = [module.namespace["colony"]]

  metadata {
    name      = "colonyd"
    namespace = local.colony_ns
    labels    = local.colonyd_labels
  }
}

resource "kubernetes_deployment_v1" "colonyd" {
  metadata {
    name      = "colonyd"
    namespace = local.colony_ns
    labels    = local.colonyd_labels
    annotations = {
      # Keel disabled 2026-08-30: every image build was auto-rolling colonyd
      # and killing in-flight agent runs (three casualties that day alone).
      # Re-enable (policy=force, trigger=poll, matchTag=true) once colony's
      # drain + adopt-and-resume scope (col-c8f58a57) makes restarts free.
      # Until then, pin an immutable image through IaC at a quiet moment
      # after verifying all scopes are paused and no runs are active.
      "keel.sh/policy" = "never"
    }
  }

  spec {
    # Must stay 1: SQLite plus in-process runs are not multi-writer.
    replicas = 1

    # Cover bounded drain, sandbox cleanup, image pull, and readiness.
    progress_deadline_seconds = local.colony_drain_timeout_seconds + 300

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "colonyd"
      }
    }

    template {
      metadata {
        labels = local.colonyd_labels
        annotations = {
          # Roll the pod when the env secret changes — env_from alone does not
          # restart the container, and keel only reacts to image digests.
          "aether.shdr.ch/env-checksum" = nonsensitive(sha256(jsonencode(local.colony_env)))
        }
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.colonyd.metadata[0].name
        automount_service_account_token = true
        # Let the daemon drain before Kubernetes can force-kill its workers.
        termination_grace_period_seconds = local.colony_drain_timeout_seconds + 60

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        volume {
          name = "colonyd-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.colonyd_data.metadata[0].name
          }
        }

        volume {
          name = "scratch"
          empty_dir {
            size_limit = "20Gi"
          }
        }

        container {
          name              = "colonyd"
          image             = local.colony_image
          image_pull_policy = "Always"

          port {
            name           = "http"
            container_port = 4400
          }

          port {
            name           = "metrics"
            container_port = 9464
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.colony_app_env.metadata[0].name
            }
          }

          volume_mount {
            name       = "colonyd-data"
            mount_path = "/var/lib/colonyd"
          }

          volume_mount {
            name       = "scratch"
            mount_path = "/tmp"
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true

            capabilities {
              drop = ["ALL"]
            }
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }

          # Liveness only guards a wedged process. The default 1s timeout
          # killed a healthy daemon mid-implementer-run when a synchronous
          # SQLite call held the event loop past a second (2026-09-03,
          # exit 143, three probes in a row); a stall that long is not a
          # hang, and a kill costs every live run its progress.
          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 20
            period_seconds        = 20
            timeout_seconds       = 10
            failure_threshold     = 6
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              # Headroom for 3 concurrent agent runs (node + git + npm each).
              cpu    = "3000m"
              memory = "6Gi"
            }
          }
        }
      }
    }
  }

  timeouts {
    update = "${local.colony_drain_timeout_seconds + 360}s"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations["kubernetes.io/change-cause"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
      # Kyverno and operator rollouts own these pod-template fields.
      spec[0].template[0].spec[0].priority_class_name,
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
    ]
  }
}

resource "kubernetes_service_v1" "colonyd" {
  depends_on = [module.namespace["colony"]]

  metadata {
    name      = "colonyd"
    namespace = local.colony_ns
    labels    = local.colonyd_labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "colonyd"
    }

    port {
      name        = "http"
      port        = 4400
      target_port = "http"
    }

    port {
      name        = "metrics"
      port        = 9464
      target_port = "metrics"
    }
  }
}

resource "kubernetes_manifest" "colonyd_route" {
  depends_on = [kubernetes_service_v1.colonyd]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "colonyd"
      namespace = local.colony_ns
      labels    = local.colonyd_labels
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.colony_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.colonyd.metadata[0].name
          port = 4400
        }]
      }]
    }
  }
}

# colonyd launches per-run sandbox pods in colony-sandboxes (the kubernetes
# sandbox engine). Scoped strictly to that namespace: create/exec/delete on
# pods and nothing else. The engine code fails closed with a clear error if
# this binding is missing.
resource "kubernetes_role_v1" "colonyd_sandbox_launcher" {
  metadata {
    name      = "colonyd-sandbox-launcher"
    namespace = module.namespace["colony-sandboxes"].name
    labels    = local.colony_labels
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["create", "get", "list", "watch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec", "pods/attach"]
    verbs      = ["create", "get"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["agents.x-k8s.io"]
    resources  = ["sandboxes"]
    verbs      = ["create", "get", "list", "watch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "colonyd_sandbox_launcher" {
  metadata {
    name      = "colonyd-sandbox-launcher"
    namespace = module.namespace["colony-sandboxes"].name
    labels    = local.colony_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.colonyd_sandbox_launcher.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.colonyd.metadata[0].name
    namespace = local.colony_ns
  }
}
