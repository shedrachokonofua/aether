# =============================================================================
# Coder - Self-Hosted Remote Development Platform
# =============================================================================

locals {
  coder_namespace        = "coder"
  coder_host             = "coder.apps.home.shdr.ch"
  coder_postgres_service = "coder-postgres"
  coder_postgres_db      = "coder"
  coder_postgres_user    = "coder"
  coder_postgres_port    = 5432
  coder_postgres_url     = "postgresql://${local.coder_postgres_user}:${random_password.coder_postgres_password.result}@${local.coder_postgres_service}.${local.coder_namespace}.svc.cluster.local:${local.coder_postgres_port}/${local.coder_postgres_db}?sslmode=disable"
}

resource "kubernetes_namespace_v1" "coder" {
  depends_on = [helm_release.cilium]

  metadata {
    name = local.coder_namespace
  }
}

resource "random_password" "coder_postgres_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "coder_postgres" {
  depends_on = [kubernetes_namespace_v1.coder]

  metadata {
    name      = "coder-postgres"
    namespace = local.coder_namespace
  }

  data = {
    POSTGRES_DB       = local.coder_postgres_db
    POSTGRES_USER     = local.coder_postgres_user
    POSTGRES_PASSWORD = random_password.coder_postgres_password.result
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "coder_secrets" {
  depends_on = [kubernetes_namespace_v1.coder]

  metadata {
    name      = "coder-secrets"
    namespace = local.coder_namespace
  }

  data = {
    pg_connection_url  = local.coder_postgres_url
    oidc_client_secret = var.coder_oauth_client_secret
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "coder_postgres_data" {
  depends_on = [kubernetes_namespace_v1.coder, kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "coder-postgres-data"
    namespace = local.coder_namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

resource "kubernetes_stateful_set_v1" "coder_postgres" {
  depends_on = [kubernetes_secret_v1.coder_postgres, kubernetes_persistent_volume_claim_v1.coder_postgres_data]

  metadata {
    name      = local.coder_postgres_service
    namespace = local.coder_namespace
    labels = {
      app = local.coder_postgres_service
    }
  }

  spec {
    service_name = local.coder_postgres_service
    replicas     = 1

    selector {
      match_labels = {
        app = local.coder_postgres_service
      }
    }

    template {
      metadata {
        labels = {
          app = local.coder_postgres_service
        }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:16"

          port {
            container_port = local.coder_postgres_port
          }

          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.coder_postgres.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }

          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.coder_postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.coder_postgres.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          readiness_probe {
            exec {
              command = ["/bin/sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            exec {
              command = ["/bin/sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.coder_postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "coder_postgres" {
  depends_on = [kubernetes_stateful_set_v1.coder_postgres]

  metadata {
    name      = local.coder_postgres_service
    namespace = local.coder_namespace
    labels = {
      app = local.coder_postgres_service
    }
  }

  spec {
    selector = {
      app = local.coder_postgres_service
    }

    port {
      port        = local.coder_postgres_port
      target_port = local.coder_postgres_port
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "helm_release" "coder" {
  depends_on = [kubernetes_secret_v1.coder_secrets, kubernetes_service_v1.coder_postgres]

  name       = "coder"
  repository = "https://helm.coder.com/v2"
  chart      = "coder"
  namespace  = local.coder_namespace
  version    = "2.31.9"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    coder = {
      service = {
        type = "ClusterIP"
        port = 80
      }

      resources = {
        requests = { cpu = "250m", memory = "256Mi" }
        limits   = { cpu = "2000m", memory = "2Gi" }
      }

      env = [
        {
          name  = "CODER_ACCESS_URL"
          value = "https://${local.coder_host}"
        },
        {
          name  = "CODER_WILDCARD_ACCESS_URL"
          value = "*.${local.coder_host}"
        },
        {
          name = "CODER_PG_CONNECTION_URL"
          valueFrom = {
            secretKeyRef = {
              name = kubernetes_secret_v1.coder_secrets.metadata[0].name
              key  = "pg_connection_url"
            }
          }
        },
        {
          name  = "CODER_OIDC_ISSUER_URL"
          value = "${var.oidc_issuer_url}"
        },
        {
          name  = "CODER_OIDC_CLIENT_ID"
          value = "coder"
        },
        {
          name = "CODER_OIDC_CLIENT_SECRET"
          valueFrom = {
            secretKeyRef = {
              name = kubernetes_secret_v1.coder_secrets.metadata[0].name
              key  = "oidc_client_secret"
            }
          }
        },
        {
          name  = "CODER_OIDC_SCOPES"
          value = "openid,profile,email,roles"
        },
        {
          name  = "CODER_OIDC_USERNAME_FIELD"
          value = "preferred_username"
        },
        {
          name  = "CODER_TELEMETRY"
          value = "false"
        },
      ]
    }
  })]
}

resource "kubernetes_manifest" "coder_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.coder]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "coder"
      namespace = local.coder_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = ["${local.coder_host}"]
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
          name = "coder"
          port = 80
        }]
      }]
    }
  }
}
