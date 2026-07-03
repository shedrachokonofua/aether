# =============================================================================
# OnlyOffice Document Server — Office editing for Nextcloud
# =============================================================================
# Runs behind the existing Gateway/Caddy TLS edge. Nextcloud uses the public
# HTTPS URL so browser and callback URLs stay on the canonical trusted host.

locals {
  onlyoffice_host         = "onlyoffice.home.shdr.ch"
  onlyoffice_url          = "https://${local.onlyoffice_host}"
  onlyoffice_internal_url = local.onlyoffice_url
  onlyoffice_storage_url  = "http://nextcloud-server.${local.nextcloud_namespace}.svc.cluster.local"

  onlyoffice_image = "onlyoffice/documentserver:latest"
  onlyoffice_port  = 80

  onlyoffice_ai_provider_url = "https://litellm.home.shdr.ch"
  onlyoffice_ai_model_id     = "aether/gemma-4-26b-a4b"
  onlyoffice_ai_model_name   = "Aether Gemma 4 26B A4B"

  onlyoffice_ai_settings_json = jsonencode({
    version = 3
    timeout = "10m"
    proxy   = ""
    allowedCorsOrigins = [
      "https://onlyoffice.github.io",
      "https://onlyoffice-plugins.github.io",
      local.onlyoffice_url,
    ]
    actions = {
      Chat = {
        name         = "Ask AI"
        icon         = "ask-ai"
        model        = local.onlyoffice_ai_model_id
        capabilities = 1
      }
      Summarization = {
        name         = "Summarization"
        icon         = "summarization"
        model        = local.onlyoffice_ai_model_id
        capabilities = 1
      }
      Translation = {
        name         = "Translation"
        icon         = "translation"
        model        = local.onlyoffice_ai_model_id
        capabilities = 1
      }
      TextAnalyze = {
        name         = "Text analysis"
        icon         = "text-analysis-ai"
        model        = local.onlyoffice_ai_model_id
        capabilities = 1
      }
    }
    providers = {
      OpenAI = {
        name = "OpenAI"
        url  = local.onlyoffice_ai_provider_url
        key  = var.secrets["litellm.virtual_keys.nextcloud"]
        models = [{
          id       = local.onlyoffice_ai_model_id
          object   = "model"
          owned_by = "aether"
          name     = local.onlyoffice_ai_model_id
          endpoints = [
            1,
          ]
          options = {
            max_input_tokens = 131072
          }
        }]
      }
    }
    models = [{
      capabilities = 1
      provider     = "OpenAI"
      name         = local.onlyoffice_ai_model_name
      id           = local.onlyoffice_ai_model_id
    }]
  })

  onlyoffice_ai_settings_hash = nonsensitive(substr(sha256(local.onlyoffice_ai_settings_json), 0, 12))

  nextcloud_onlyoffice_bootstrap_hash = nonsensitive(substr(sha256(join("|", [
    local.onlyoffice_url,
    local.onlyoffice_internal_url,
    local.onlyoffice_storage_url,
    random_password.onlyoffice_jwt_secret.result,
    "Authorization",
  ])), 0, 12))

  onlyoffice_labels = { app = "onlyoffice" }
}

# =============================================================================
# Secret
# =============================================================================

resource "random_password" "onlyoffice_jwt_secret" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "onlyoffice_jwt" {
  depends_on = [module.namespace["nextcloud"]]

  metadata {
    name      = "onlyoffice-jwt"
    namespace = module.namespace["nextcloud"].name
  }

  data = {
    JWT_SECRET = random_password.onlyoffice_jwt_secret.result
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "onlyoffice_ai_settings" {
  depends_on = [module.namespace["nextcloud"]]

  metadata {
    name      = "onlyoffice-ai-settings"
    namespace = module.namespace["nextcloud"].name
  }

  data = {
    "ai-settings.json" = local.onlyoffice_ai_settings_json
  }

  type = "Opaque"
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "onlyoffice" {
  depends_on = [
    kubernetes_secret_v1.onlyoffice_ai_settings,
    kubernetes_secret_v1.onlyoffice_jwt,
  ]

  metadata {
    name      = "onlyoffice"
    namespace = module.namespace["nextcloud"].name
    labels    = local.onlyoffice_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.onlyoffice_labels
    }

    template {
      metadata {
        labels = local.onlyoffice_labels
        annotations = {
          "aether.shdr.ch/ai-settings-sha" = local.onlyoffice_ai_settings_hash
        }
      }

      spec {
        container {
          name  = "documentserver"
          image = local.onlyoffice_image

          # Preserve the old Dokploy HTTPS-awareness patch while keeping TLS at
          # Caddy/Gateway. OnlyOffice otherwise may generate http callback URLs.
          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            if [ -f /etc/onlyoffice/documentserver/nginx/includes/http-common.conf ]; then
              sed -i "s/[$]the_scheme[;]/https;/g" /etc/onlyoffice/documentserver/nginx/includes/http-common.conf
            fi
            if [ -f /run/onlyoffice-ai/ai-settings.json ]; then
              python3 -c 'import json; local_json="/etc/onlyoffice/documentserver/local.json"; ai_settings_json="/run/onlyoffice-ai/ai-settings.json"; config=json.load(open(local_json, encoding="utf-8")); config["aiSettings"]=json.load(open(ai_settings_json, encoding="utf-8")); f=open(local_json, "w", encoding="utf-8"); json.dump(config, f, indent=2); f.write(chr(10)); f.close()'
            fi
            /app/ds/run-document-server.sh 2>&1 | sed -u -E 's/"key": "[^"]+"/"key": "[REDACTED]"/g'
          EOT
          ]

          port {
            container_port = local.onlyoffice_port
            name           = "http"
          }

          env {
            name  = "JWT_ENABLED"
            value = "true"
          }

          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.onlyoffice_jwt.metadata[0].name
                key  = "JWT_SECRET"
              }
            }
          }

          env {
            name  = "JWT_HEADER"
            value = "Authorization"
          }

          volume_mount {
            name       = "ai-settings"
            mount_path = "/run/onlyoffice-ai/ai-settings.json"
            sub_path   = "ai-settings.json"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = local.onlyoffice_port
              http_header {
                name  = "Host"
                value = local.onlyoffice_host
              }
            }
            initial_delay_seconds = 90
            period_seconds        = 15
            failure_threshold     = 12
          }

          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = local.onlyoffice_port
              http_header {
                name  = "Host"
                value = local.onlyoffice_host
              }
            }
            initial_delay_seconds = 180
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "3"
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "ai-settings"
          secret {
            secret_name = kubernetes_secret_v1.onlyoffice_ai_settings.metadata[0].name
            items {
              key  = "ai-settings.json"
              path = "ai-settings.json"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "onlyoffice" {
  depends_on = [kubernetes_deployment_v1.onlyoffice]

  metadata {
    name      = "onlyoffice"
    namespace = module.namespace["nextcloud"].name
    labels    = local.onlyoffice_labels
  }

  spec {
    selector = local.onlyoffice_labels

    port {
      name        = "http"
      port        = local.onlyoffice_port
      target_port = local.onlyoffice_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Nextcloud OnlyOffice connector bootstrap
# =============================================================================

resource "kubernetes_job_v1" "nextcloud_onlyoffice_bootstrap" {
  timeouts {
    create = "15m"
  }

  depends_on = [
    kubernetes_deployment_v1.nextcloud_server,
    kubernetes_service_v1.nextcloud_server,
    kubernetes_service_v1.onlyoffice,
    kubernetes_secret_v1.onlyoffice_jwt,
  ]

  metadata {
    name      = "nextcloud-onlyoffice-bootstrap-${local.nextcloud_onlyoffice_bootstrap_hash}"
    namespace = module.namespace["nextcloud"].name
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = { app = "nextcloud-onlyoffice-bootstrap" }
      }

      spec {
        restart_policy = "OnFailure"

        # Co-locate with the server pod for RWO custom-apps PVC sharing.
        affinity {
          pod_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "app"
                  operator = "In"
                  values   = [local.nextcloud_server_labels.app]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        container {
          name  = "occ"
          image = local.nextcloud_server_image

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }

          command = ["/bin/sh", "-c", <<-EOT
            set -eu
            rsync -rlDog --chown=www-data:www-data \
              --exclude=/data/ \
              --exclude=/custom_apps/ --exclude=/themes/ \
              /usr/src/nextcloud/ /var/www/html/
            echo "Waiting for Nextcloud server to be installed..."
            for i in $(seq 1 60); do
              code=$(curl -s -o /tmp/status.json -w '%%{http_code}' \
                -H "Host: $${NEXTCLOUD_HOST}" \
                http://nextcloud-server.${local.nextcloud_namespace}.svc.cluster.local/status.php || true)
              if [ "$code" = "200" ] && grep -q '"installed":true' /tmp/status.json; then
                break
              fi
              sleep 5
            done

            echo "Waiting for OnlyOffice Document Server..."
            for i in $(seq 1 60); do
              if curl -fsS http://onlyoffice.${local.nextcloud_namespace}.svc.cluster.local/healthcheck >/dev/null; then
                break
              fi
              sleep 5
            done

            cd /var/www/html
            runuser -u www-data -- php occ status
            runuser -u www-data -- php occ app:install onlyoffice || runuser -u www-data -- php occ app:enable onlyoffice
            runuser -u www-data -- php occ config:app:set onlyoffice DocumentServerUrl --value="$${ONLYOFFICE_URL}/"
            runuser -u www-data -- php occ config:app:set onlyoffice DocumentServerInternalUrl --value="$${ONLYOFFICE_INTERNAL_URL}/"
            runuser -u www-data -- php occ config:app:set onlyoffice StorageUrl --value="$${ONLYOFFICE_STORAGE_URL}/"
            runuser -u www-data -- php occ config:app:set onlyoffice jwt_secret --value="$${JWT_SECRET}"
            runuser -u www-data -- php occ config:app:set onlyoffice jwt_header --value="Authorization"
          EOT
          ]

          env {
            name  = "NEXTCLOUD_HOST"
            value = local.nextcloud_host
          }

          env {
            name  = "ONLYOFFICE_URL"
            value = local.onlyoffice_url
          }

          env {
            name  = "ONLYOFFICE_INTERNAL_URL"
            value = local.onlyoffice_internal_url
          }

          env {
            name  = "ONLYOFFICE_STORAGE_URL"
            value = local.onlyoffice_storage_url
          }

          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.onlyoffice_jwt.metadata[0].name
                key  = "JWT_SECRET"
              }
            }
          }

          volume_mount {
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/html/data"
          }

          volume_mount {
            name       = "config"
            mount_path = "/var/www/html/config/nextcloud-k8s.config.php"
            sub_path   = "nextcloud-k8s.config.php"
            read_only  = true
          }

          volume_mount {
            name       = "install-state"
            mount_path = "/var/www/html/config/install-state.config.php"
            sub_path   = "install-state.config.php"
            read_only  = true
          }
        }

        volume {
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_custom_apps.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_data.metadata[0].name
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_config.metadata[0].name
            items {
              key  = "nextcloud-k8s.config.php"
              path = "nextcloud-k8s.config.php"
            }
          }
        }

        volume {
          name = "install-state"
          secret {
            secret_name = kubernetes_secret_v1.nextcloud_install_state.metadata[0].name
            items {
              key  = "install-state.config.php"
              path = "install-state.config.php"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template]
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "onlyoffice_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.onlyoffice]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "onlyoffice"
      namespace = local.nextcloud_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.onlyoffice_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" },
              { name = "X-Forwarded-Host", value = local.onlyoffice_host },
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.onlyoffice.metadata[0].name
          port = local.onlyoffice_port
        }]
      }]
    }
  }
}

output "onlyoffice_url" {
  value = local.onlyoffice_url
}
