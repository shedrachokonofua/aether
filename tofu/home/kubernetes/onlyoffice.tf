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
  depends_on = [kubernetes_namespace_v1.nextcloud]

  metadata {
    name      = "onlyoffice-jwt"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  data = {
    JWT_SECRET = random_password.onlyoffice_jwt_secret.result
  }

  type = "Opaque"
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "onlyoffice" {
  depends_on = [kubernetes_secret_v1.onlyoffice_jwt]

  metadata {
    name      = "onlyoffice"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
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
            exec /app/ds/run-document-server.sh
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
      }
    }
  }
}

resource "kubernetes_service_v1" "onlyoffice" {
  depends_on = [kubernetes_deployment_v1.onlyoffice]

  metadata {
    name      = "onlyoffice"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
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
  depends_on = [
    kubernetes_deployment_v1.nextcloud_server,
    kubernetes_service_v1.nextcloud_server,
    kubernetes_service_v1.onlyoffice,
    kubernetes_secret_v1.onlyoffice_jwt,
  ]

  metadata {
    name      = "nextcloud-onlyoffice-bootstrap-${local.nextcloud_onlyoffice_bootstrap_hash}"
    namespace = kubernetes_namespace_v1.nextcloud.metadata[0].name
  }

  spec {
    backoff_limit              = 6
    ttl_seconds_after_finished = 86400

    template {
      metadata {
        labels = { app = "nextcloud-onlyoffice-bootstrap" }
      }

      spec {
        restart_policy = "OnFailure"

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
            name       = "app"
            mount_path = "/var/www/html"
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
        }

        volume {
          name = "app"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.nextcloud_app.metadata[0].name
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
