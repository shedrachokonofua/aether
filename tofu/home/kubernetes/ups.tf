# =============================================================================
# UPS monitoring
# =============================================================================
# Migrated from the old podman VM to Kubernetes.

locals {
  ups_namespace = kubernetes_namespace_v1.infra.metadata[0].name
  ups_labels    = { app = "ups-management" }
  ups_host      = "peanut.apps.home.shdr.ch"

  ups_nut_port      = 3493
  ups_peanut_port   = 8080
  ups_exporter_port = 9199
}

resource "kubernetes_secret_v1" "ups_config" {
  depends_on = [kubernetes_namespace_v1.infra]

  metadata {
    name      = "ups-config"
    namespace = local.ups_namespace
  }

  data = {
    "nut.conf" = <<-EOT
      MODE=netserver
    EOT

    "ups.conf" = <<-EOT
      [ups]
          driver = snmp-ups
          port = 192.168.2.223
          desc = "Aether UPS"
          snmp_version = v3
          secLevel = authNoPriv
          secName = ${var.secrets["ups.snmp_username"]}
          authPassword = ${var.secrets["ups.snmp_auth_password"]}
          authProtocol = SHA
    EOT

    "upsd.conf" = <<-EOT
      LISTEN 0.0.0.0 ${local.ups_nut_port}
      LISTEN 127.0.0.1 ${local.ups_nut_port}
    EOT

    "upsd.users" = <<-EOT
      [${var.secrets["ups.nut_username"]}]
          password = ${var.secrets["ups.nut_password"]}
          upsmon master
          actions = SET
          instcmds = ALL
    EOT

    "peanut-settings.yml" = <<-EOT
      NUT_SERVERS:
        - HOST: localhost
          PORT: ${local.ups_nut_port}
          USERNAME: ${var.secrets["ups.nut_username"]}
          PASSWORD: ${var.secrets["ups.nut_password"]}
    EOT
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "ups_management" {
  depends_on = [kubernetes_secret_v1.ups_config]

  metadata {
    name      = "ups-management"
    namespace = local.ups_namespace
    labels    = local.ups_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.ups_labels
    }

    template {
      metadata {
        labels = local.ups_labels
      }

      spec {
        init_container {
          name  = "prepare-nut-config"
          image = "busybox:latest"

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }

          command = [
            "sh",
            "-c",
            "cp /secret-config/* /etc/nut/ && chown -R 100:101 /etc/nut && chmod 640 /etc/nut/*",
          ]

          volume_mount {
            name       = "nut-secret"
            mount_path = "/secret-config"
            read_only  = true
          }

          volume_mount {
            name       = "nut-config"
            mount_path = "/etc/nut"
          }
        }

        container {
          name  = "nut-server"
          image = "ghcr.io/tigattack/nut-upsd:latest"

          port {
            container_port = local.ups_nut_port
            name           = "nut"
          }

          volume_mount {
            name       = "nut-config"
            mount_path = "/etc/nut"
          }

          volume_mount {
            name       = "nut-run"
            mount_path = "/var/run/nut"
          }

          security_context {
            run_as_user  = 100
            run_as_group = 101
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.ups_nut_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = local.ups_nut_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        container {
          name  = "peanut"
          image = "docker.io/brandawg93/peanut:latest"

          port {
            container_port = local.ups_peanut_port
            name           = "http"
          }

          env {
            name  = "WEB_PORT"
            value = tostring(local.ups_peanut_port)
          }

          volume_mount {
            name       = "peanut-config"
            mount_path = "/config/settings.yml"
            sub_path   = "peanut-settings.yml"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = local.ups_peanut_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.ups_peanut_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        container {
          name  = "nut-exporter"
          image = "ghcr.io/druggeri/nut_exporter:latest"

          port {
            container_port = local.ups_exporter_port
            name           = "metrics"
          }

          env {
            name  = "NUT_EXPORTER_SERVER"
            value = "localhost"
          }

          env {
            name  = "NUT_EXPORTER_SERVERPORT"
            value = tostring(local.ups_nut_port)
          }

          env {
            name  = "NUT_EXPORTER_USERNAME"
            value = var.secrets["ups.nut_username"]
          }

          env {
            name  = "NUT_EXPORTER_PASSWORD"
            value = var.secrets["ups.nut_password"]
          }

          env {
            name  = "NUT_EXPORTER_VARIABLES"
            value = ""
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.ups_exporter_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            tcp_socket {
              port = local.ups_exporter_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "nut-config"
          empty_dir {}
        }

        volume {
          name = "nut-secret"
          secret {
            secret_name  = kubernetes_secret_v1.ups_config.metadata[0].name
            default_mode = "0440"
            items {
              key  = "nut.conf"
              path = "nut.conf"
            }
            items {
              key  = "ups.conf"
              path = "ups.conf"
            }
            items {
              key  = "upsd.conf"
              path = "upsd.conf"
            }
            items {
              key  = "upsd.users"
              path = "upsd.users"
            }
          }
        }

        volume {
          name = "peanut-config"
          secret {
            secret_name  = kubernetes_secret_v1.ups_config.metadata[0].name
            default_mode = "0444"
            items {
              key  = "peanut-settings.yml"
              path = "peanut-settings.yml"
            }
          }
        }

        volume {
          name = "nut-run"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "ups_management" {
  depends_on = [kubernetes_deployment_v1.ups_management]

  metadata {
    name      = "ups-management"
    namespace = local.ups_namespace
    labels    = local.ups_labels
  }

  spec {
    selector = local.ups_labels

    port {
      name        = "http"
      port        = local.ups_peanut_port
      target_port = local.ups_peanut_port
      protocol    = "TCP"
    }

    port {
      name        = "nut"
      port        = local.ups_nut_port
      target_port = local.ups_nut_port
      protocol    = "TCP"
    }

    port {
      name        = "metrics"
      port        = local.ups_exporter_port
      target_port = local.ups_exporter_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_manifest" "ups_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.ups_management]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "ups-management"
      namespace = local.ups_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.ups_host]
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
              { name = "X-Forwarded-Proto", value = "https" }
            ]
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.ups_management.metadata[0].name
          port = local.ups_peanut_port
        }]
      }]
    }
  }
}
