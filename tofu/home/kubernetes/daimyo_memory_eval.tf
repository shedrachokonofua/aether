# Daimyo memory eval: a nightly run that scores agent memory in org `qa`
# against two baselines that use no memory system (daimyo repo
# scripts/memory_eval/README.md and
# docs/specs/2026-11-23-automatic-memory-design.md §3.1).
#
# Three parts:
#   - an issuer the `qa` Org trusts for throwaway persons. The harness signs a
#     token per test history with one P-256 key; the Deployment here only
#     serves that key's discovery document and JWKS. The Org maps the token's
#     `sub` with the prefix `user:eval-`, so the key can name `eval-…`
#     persons of org qa and nobody else.
#   - `memory-keeper`, the test agent: an omp harness agent with a per-user
#     memory mount and nothing else to reach.
#   - a CronJob that runs the private and canary suites and ships the scores
#     as metrics. A canary leak fails the Job.
#
# Secrets (SOPS): daimyo.memory_eval_issuer_key_b64 (a P-256 private key in
# PEM, base64) and litellm.virtual_keys.memory_eval (registered by
# `task configure:litellm-keys` with the allowlist in
# ansible/playbooks/register_litellm_virtual_keys.yml).

locals {
  memory_eval_ns = module.namespace["daimyo-memory-eval"].name
  # 5706fcc (main pipeline 16753, build:memory-eval; the image's verify stage
  # runs the harness's unit tests).
  memory_eval_image      = "registry.gitlab.home.shdr.ch/so/daimyo/memory-eval@sha256:e66b0ec8310c701297401cc2c46fb70bd34b799465b27cffe7e7e66b7eb0302b"
  memory_eval_issuer_url = "http://memory-eval-issuer.daimyo-memory-eval.svc:8080"
  memory_eval_labels     = { app = "daimyo-memory-eval" }
  memory_eval_agent      = "memory-keeper"
  memory_eval_store      = "memory-eval"
  # The answering model of every arm, and the test agent's model, so the arms
  # differ only in what the model is given.
  memory_eval_answer_model = "moira/flash"
  memory_eval_judge_model  = "moira/balanced"
  memory_eval_pod_security = {
    runAsNonRoot   = true
    runAsUser      = 65534
    runAsGroup     = 65534
    fsGroup        = 65534
    seccompProfile = { type = "RuntimeDefault" }
  }
  memory_eval_container_security = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    capabilities             = { drop = ["ALL"] }
  }
}

resource "kubernetes_secret_v1" "memory_eval_registry" {
  metadata {
    name      = "daimyo-gitlab-registry"
    namespace = local.memory_eval_ns
    labels    = local.memory_eval_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.daimyo_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "memory_eval" {
  metadata {
    name      = "memory-eval"
    namespace = local.memory_eval_ns
    labels    = local.memory_eval_labels
  }

  data = {
    "issuer-key.pem" = base64decode(var.secrets["daimyo.memory_eval_issuer_key_b64"])
    "litellm-key"    = var.secrets["litellm.virtual_keys.memory_eval"]
  }
}

resource "kubectl_manifest" "memory_eval_issuer" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "memory-eval-issuer"
      namespace = local.memory_eval_ns
      labels    = merge(local.memory_eval_labels, { component = "issuer" })
    }
    spec = {
      replicas = 1
      selector = { matchLabels = merge(local.memory_eval_labels, { component = "issuer" }) }
      template = {
        metadata = {
          labels = merge(local.memory_eval_labels, { component = "issuer" })
          # A changed key restarts the pod, which reads the key once.
          annotations = { "aether.shdr.ch/key-sha" = sha256(var.secrets["daimyo.memory_eval_issuer_key_b64"]) }
        }
        spec = {
          automountServiceAccountToken = false
          imagePullSecrets             = [{ name = kubernetes_secret_v1.memory_eval_registry.metadata[0].name }]
          securityContext              = local.memory_eval_pod_security
          containers = [{
            name  = "issuer"
            image = local.memory_eval_image
            args  = ["issuer", "--port", "8080"]
            env = [
              { name = "MEMORY_EVAL_ISSUER_KEY", value = "/keys/issuer-key.pem" },
              { name = "MEMORY_EVAL_ISSUER_URL", value = local.memory_eval_issuer_url },
            ]
            ports           = [{ name = "http", containerPort = 8080 }]
            readinessProbe  = { httpGet = { path = "/healthz", port = 8080 }, periodSeconds = 5 }
            livenessProbe   = { httpGet = { path = "/healthz", port = 8080 }, periodSeconds = 20 }
            securityContext = local.memory_eval_container_security
            resources = {
              requests = { cpu = "10m", memory = "48Mi" }
              limits   = { memory = "128Mi" }
            }
            volumeMounts = [{ name = "keys", mountPath = "/keys", readOnly = true }]
          }]
          volumes = [{
            name = "keys"
            secret = {
              secretName = kubernetes_secret_v1.memory_eval.metadata[0].name
              items      = [{ key = "issuer-key.pem", path = "issuer-key.pem" }]
            }
          }]
        }
      }
    }
  })
}

resource "kubectl_manifest" "memory_eval_issuer_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "memory-eval-issuer"
      namespace = local.memory_eval_ns
      labels    = local.memory_eval_labels
    }
    spec = {
      selector = merge(local.memory_eval_labels, { component = "issuer" })
      ports    = [{ name = "http", port = 8080, targetPort = 8080 }]
    }
  })
}

# The test agent. It answers from its per-user memory mount and has no other
# grant: no web, no shell, no MCP server.
resource "kubectl_manifest" "memory_eval_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = local.memory_eval_agent
      namespace = "org-qa"
      labels    = local.daimyo_qa_labels
    }
    spec = {
      project     = "qa"
      description = "Memory eval test agent: answers questions from its per-user memory."
      harness = {
        kind         = "omp"
        model        = local.memory_eval_answer_model
        systemPrompt = "You are a personal assistant with a memory of the person you are talking to. Your memory is the files under /memory. Answer from what your memory says about them. If your memory does not hold the answer, say that you do not know. Keep answers short."
        tools        = { bash = false, files = true, web = false }
        maxTurns     = 30
      }
      resources = {
        cpu       = "1"
        memory    = "1Gi"
        workspace = "1Gi"
        requests  = { cpu = "100m", memory = "256Mi" }
      }
      operations = [{ name = "chat", deadline = "15m" }]
      grants = [
        { name = "models", model = { models = [local.memory_eval_answer_model], budgetUsd = 1 } },
      ]
      memory = [{
        store       = local.memory_eval_store
        scope       = "perUser"
        access      = "write"
        description = "What you know about the person you are talking to."
      }]
      sessions  = { enabled = true, idleTtl = "15m", maxLifetime = "1d" }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

# 07:10 UTC, after the day's conversations and before the 09:00 UTC dreams.
resource "kubectl_manifest" "memory_eval_cron" {
  depends_on = [kubectl_manifest.memory_eval_agent, kubectl_manifest.memory_eval_issuer]

  yaml_body = yamlencode({
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata = {
      name      = "memory-eval"
      namespace = local.memory_eval_ns
      labels    = merge(local.memory_eval_labels, { component = "run" })
    }
    spec = {
      schedule                   = "10 7 * * *"
      concurrencyPolicy          = "Forbid"
      successfulJobsHistoryLimit = 3
      failedJobsHistoryLimit     = 3
      jobTemplate = {
        spec = {
          backoffLimit            = 0
          activeDeadlineSeconds   = 4 * 60 * 60
          ttlSecondsAfterFinished = 7 * 24 * 60 * 60
          template = {
            metadata = { labels = merge(local.memory_eval_labels, { component = "run" }) }
            spec = {
              restartPolicy                = "Never"
              automountServiceAccountToken = false
              imagePullSecrets             = [{ name = kubernetes_secret_v1.memory_eval_registry.metadata[0].name }]
              securityContext              = local.memory_eval_pod_security
              containers = [{
                name    = "run"
                image   = local.memory_eval_image
                command = ["sh", "-c"]
                # Each suite runs whatever the one before it did; a canary
                # leak (exit 1) fails the Job after the scores are shipped.
                args = [<<-EOT
                  run=$(date -u +%Y%m%d%H%M)
                  python3 -m memory_eval run --suite private --arms full-context,raw-search,memory \
                    --n 12 --seed 1 --run "$run" --out /out/private --concurrency 2 \
                    --answer-model ${local.memory_eval_answer_model} --judge-model ${local.memory_eval_judge_model}
                  private=$?
                  python3 -m memory_eval run --suite canary --arms memory \
                    --n 2 --seed 1 --run "$run" --out /out/canary --concurrency 2 \
                    --answer-model ${local.memory_eval_answer_model} --judge-model ${local.memory_eval_judge_model}
                  canary=$?
                  echo "private=$private canary=$canary"
                  [ "$private" = 0 ] && [ "$canary" = 0 ]
                EOT
                ]
                env = [
                  { name = "LITELLM_BASE_URL", value = "${local.daimyo_litellm_upstream}/v1" },
                  { name = "LITELLM_API_KEY", valueFrom = { secretKeyRef = { name = kubernetes_secret_v1.memory_eval.metadata[0].name, key = "litellm-key" } } },
                  { name = "DAIMYO_SERVER", value = "http://daimyo-api.${local.daimyo_ns}.svc:80" },
                  { name = "MEMORY_EVAL_ORG", value = "qa" },
                  { name = "MEMORY_EVAL_PROJECT", value = "qa" },
                  { name = "MEMORY_EVAL_AGENT", value = local.memory_eval_agent },
                  { name = "MEMORY_EVAL_STORE", value = local.memory_eval_store },
                  { name = "MEMORY_EVAL_ISSUER_KEY", value = "/keys/issuer-key.pem" },
                  { name = "MEMORY_EVAL_ISSUER_URL", value = local.memory_eval_issuer_url },
                  { name = "MEMORY_EVAL_CACHE", value = "/out/cache" },
                  { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318" },
                ]
                securityContext = local.memory_eval_container_security
                resources = {
                  requests = { cpu = "50m", memory = "128Mi" }
                  limits   = { memory = "512Mi" }
                }
                volumeMounts = [
                  { name = "keys", mountPath = "/keys", readOnly = true },
                  { name = "out", mountPath = "/out" },
                ]
              }]
              volumes = [
                {
                  name = "keys"
                  secret = {
                    secretName = kubernetes_secret_v1.memory_eval.metadata[0].name
                    items      = [{ key = "issuer-key.pem", path = "issuer-key.pem" }]
                  }
                },
                { name = "out", emptyDir = { sizeLimit = "1Gi" } },
              ]
            }
          }
        }
      }
    }
  })
}
