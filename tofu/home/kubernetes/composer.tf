# =============================================================================
# Composer API — self-hosted OpenAI-compatible endpoint for Cursor Composer
# =============================================================================
# Upstream (standardagents/composer-api) ships only a macOS app and a Cloudflare
# Worker — there is no container image for the OpenAI front door. We run it on
# aether with NO code changes:
#
#   - init container  : pulls the pinned upstream source + `npm ci` into /app
#   - bridge container: `cursor-sdk-bridge` — talks to Cursor with the API key
#   - frontend        : the upstream Worker, run verbatim by `wrangler dev`
#                       (workerd) with a trimmed config that drops all
#                       Cloudflare-only bindings (D1/R2/Durable Objects). It
#                       reaches the bridge over localhost.
#
# Auth: this runs in "direct" mode — callers send their Cursor API key as the
# Bearer token (e.g. `Authorization: Bearer crsr_...`). Nothing is stored.
#
# Endpoint: https://composer.home.shdr.ch/v1  (chat/completions, responses, models)

locals {
  composer_image       = "node:22"
  composer_host        = "composer.home.shdr.ch"
  composer_port        = 8787
  composer_bridge_port = 8792
  composer_ns          = kubernetes_namespace_v1.personal.metadata[0].name
  composer_labels      = { app = "composer" }

  # Pinned to the exact commit validated locally (chat/completions verified).
  composer_commit = "d3eabd756c33cd7758db408f9adad623124df570"

  # Trimmed wrangler config: upstream Worker, Cloudflare-only bindings removed,
  # front door -> bridge on localhost (same pod).
  composer_wrangler = {
    name                = "composer-api"
    main                = "worker/index.ts"
    compatibility_date  = "2026-05-20"
    compatibility_flags = ["nodejs_compat"]
    vars = {
      CURSOR_API_BASE           = "https://api.cursor.com"
      CURSOR_CLIENT_VERSION     = "2.6.22"
      CURSOR_SDK_CLIENT_VERSION = "sdk-1.0.13"
      WAITLIST_SOURCE           = "cursor-api"
      CURSOR_SDK_BRIDGE_URL     = "http://127.0.0.1:${local.composer_bridge_port}/sdk"
    }
  }

  composer_init_script = <<-EOT
    set -euo pipefail
    echo "Fetching composer-api @ ${local.composer_commit}"
    curl -fsSL "https://github.com/standardagents/composer-api/archive/${local.composer_commit}.tar.gz" -o /tmp/src.tgz
    tar xzf /tmp/src.tgz --strip-components=1 -C /app
    cp /config/wrangler.jsonc /app/wrangler.selfhost.jsonc
    node /config/patch-fast.cjs
    cd /app
    npm ci --no-audit --no-fund
    echo "init complete"
  EOT

  # Upstream's bridge sends only { id } to the Cursor SDK and collapses both
  # composer-2.5 and composer-2.5-fast to "default", discarding the speed tier.
  # The live Cursor catalog (verified via models.list with our key) exposes fast
  # as a PARAMETER of composer-2.5, not a separate id:
  #   composer-2.5      -> { id: "composer-2.5", params: [{ id: "fast", value: "false" }] }
  #   composer-2.5-fast -> { id: "composer-2.5", params: [{ id: "fast", value: "true"  }] }
  # Both selections were confirmed accepted end-to-end. This patch rewrites the
  # one-line model mapping; it fails loudly if upstream changes that line.
  composer_fast_patch = <<-EOT
    const fs = require("fs");
    const f = "/app/scripts/cursor-sdk-local-agent-bridge.mjs";
    const s = fs.readFileSync(f, "utf8");
    const oldLine = '  if (normalized === "composer-2.5" || normalized === "composer-2.5-fast") return { id: "default" };';
    const newLines = [
      '  if (normalized === "composer-2.5") return { id: "composer-2.5", params: [{ id: "fast", value: "false" }] };',
      '  if (normalized === "composer-2.5-fast") return { id: "composer-2.5", params: [{ id: "fast", value: "true" }] };'
    ].join("\n");
    if (!s.includes(oldLine)) {
      console.error("fast-model patch FAILED: upstream mapping line not found");
      process.exit(1);
    }
    fs.writeFileSync(f, s.replace(oldLine, newLines));
    console.log("fast-model patch applied");
  EOT
}

resource "kubernetes_config_map_v1" "composer_wrangler" {
  depends_on = [kubernetes_namespace_v1.personal]

  metadata {
    name      = "composer-wrangler"
    namespace = local.composer_ns
  }

  data = {
    "wrangler.jsonc" = jsonencode(local.composer_wrangler)
    "patch-fast.cjs" = local.composer_fast_patch
  }
}

resource "kubernetes_deployment_v1" "composer" {
  depends_on = [kubernetes_config_map_v1.composer_wrangler]

  # The init container pulls source + installs deps at pod start; don't block the
  # apply on a slow first rollout (image pull + npm ci). Verify with kubectl.
  wait_for_rollout = false

  metadata {
    name      = "composer"
    namespace = local.composer_ns
    labels    = local.composer_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.composer_labels
    }

    template {
      metadata {
        labels = local.composer_labels
        annotations = {
          "aether.shdr.ch/composer-commit" = local.composer_commit
        }
      }

      spec {
        enable_service_links = false

        init_container {
          name    = "fetch"
          image   = local.composer_image
          command = ["bash", "-lc", local.composer_init_script]

          env {
            name  = "HOME"
            value = "/app"
          }
          env {
            name  = "npm_config_cache"
            value = "/app/.npm"
          }

          volume_mount {
            name       = "app"
            mount_path = "/app"
          }
          volume_mount {
            name       = "wrangler-config"
            mount_path = "/config"
            read_only  = true
          }

          resources {
            requests = { cpu = "200m", memory = "384Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
        }

        # Back half: talks to Cursor's servers with the per-request API key.
        container {
          name        = "bridge"
          image       = local.composer_image
          working_dir = "/app"
          command     = ["node", "scripts/cursor-sdk-local-agent-bridge.mjs"]

          env {
            name  = "CURSOR_SDK_BRIDGE_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "CURSOR_SDK_BRIDGE_PORT"
            value = tostring(local.composer_bridge_port)
          }

          port {
            container_port = local.composer_bridge_port
            name           = "bridge"
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.composer_bridge_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          volume_mount {
            name       = "app"
            mount_path = "/app"
          }
        }

        # Front door: the upstream Worker, run verbatim by wrangler/workerd.
        container {
          name        = "frontend"
          image       = local.composer_image
          working_dir = "/app"
          command     = ["./node_modules/.bin/wrangler", "dev", "-c", "wrangler.selfhost.jsonc", "--ip", "0.0.0.0", "--port", tostring(local.composer_port)]

          env {
            name  = "HOME"
            value = "/app"
          }
          env {
            name  = "WRANGLER_SEND_METRICS"
            value = "false"
          }
          env {
            name  = "CI"
            value = "true"
          }

          port {
            container_port = local.composer_port
            name           = "http"
          }

          readiness_probe {
            http_get {
              path = "/v1/models"
              port = local.composer_port
              http_header {
                name  = "Authorization"
                value = "Bearer probe"
              }
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 30
          }

          liveness_probe {
            tcp_socket {
              port = local.composer_port
            }
            initial_delay_seconds = 150
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = { cpu = "200m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "1Gi" }
          }

          volume_mount {
            name       = "app"
            mount_path = "/app"
          }
        }

        volume {
          name = "app"
          empty_dir {}
        }

        volume {
          name = "wrangler-config"
          config_map {
            name = kubernetes_config_map_v1.composer_wrangler.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "composer" {
  depends_on = [kubernetes_deployment_v1.composer]

  metadata {
    name      = "composer"
    namespace = local.composer_ns
    labels    = local.composer_labels
  }

  spec {
    selector = local.composer_labels

    port {
      port        = local.composer_port
      target_port = local.composer_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "composer_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.composer]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "composer"
      namespace = local.composer_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.composer_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.composer.metadata[0].name
          port = local.composer_port
        }]
      }]
    }
  }
}
