# =============================================================================
# Firecrawl - Web Crawling + MCP
# =============================================================================
# Migrated from the legacy Podman VM to Kubernetes.

locals {
  firecrawl_image            = "ghcr.io/firecrawl/firecrawl:latest"
  firecrawl_playwright_image = "ghcr.io/firecrawl/playwright-service:latest"
  firecrawl_postgres_image   = "ghcr.io/firecrawl/nuq-postgres:latest"
  firecrawl_cnpg_image       = "registry.gitlab.home.shdr.ch/so/aether/aether-k8s-arch-labeler/firecrawl-cnpg:17.10-barman-uid999-20260702@sha256:626fe0232862aab001ef424811764a96abb025a4e2011c6c939fa37d82188d20"
  firecrawl_redis_image      = "docker.io/redis:alpine"
  firecrawl_rabbitmq_image   = "docker.io/rabbitmq:3-management"
  firecrawl_mcp_image        = "docker.io/node:22-alpine"

  firecrawl_host         = "firecrawl.home.shdr.ch"
  firecrawl_mcp_host     = "firecrawl-mcp.home.shdr.ch"
  firecrawl_ns           = module.namespace["firecrawl"].name
  firecrawl_source_ns    = "infra"
  firecrawl_labels       = { app = "firecrawl" }
  firecrawl_cnpg_cluster = "firecrawl-cnpg"
  firecrawl_db_user      = "firecrawl"

  firecrawl_api_port        = 3002
  firecrawl_mcp_port        = 3007
  firecrawl_playwright_port = 3000
  firecrawl_postgres_port   = 5432

  firecrawl_db_source_service = "${local.firecrawl_cnpg_cluster}-rw.${local.firecrawl_source_ns}.svc.cluster.local"
  firecrawl_db_service        = "${local.firecrawl_cnpg_cluster}-rw.${local.firecrawl_ns}.svc.cluster.local"
  firecrawl_registry_host     = "registry.gitlab.home.shdr.ch"
  firecrawl_registry_user     = var.secrets["gitlab.root_email"]
  firecrawl_registry_pass     = var.secrets["gitlab.root_password"]
}

# =============================================================================
# Secrets + Storage
# =============================================================================

resource "kubernetes_secret_v1" "firecrawl_env" {
  depends_on = [module.namespace["firecrawl"]]

  metadata {
    name      = "firecrawl-env"
    namespace = local.firecrawl_ns
  }

  data = {
    DATABASE_PASSWORD = var.secrets["firecrawl.database_password"]
    BULL_AUTH_KEY     = var.secrets["firecrawl.bull_auth_key"]
    TEST_API_KEY      = var.secrets["firecrawl.api_key"]
    FIRECRAWL_API_KEY = var.secrets["firecrawl.api_key"]
    OPENAI_API_KEY    = var.secrets["litellm.virtual_keys.firecrawl"]
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "firecrawl_cnpg_superuser" {
  depends_on = [module.namespace["firecrawl"]]

  metadata {
    name      = "firecrawl-cnpg-superuser"
    namespace = local.firecrawl_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = "postgres"
    password = var.secrets["firecrawl.database_password"]
  }
}

resource "kubernetes_secret_v1" "firecrawl_cnpg_app" {
  depends_on = [module.namespace["firecrawl"]]

  metadata {
    name      = "firecrawl-cnpg-app"
    namespace = local.firecrawl_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.firecrawl_db_user
    password = var.secrets["firecrawl.database_password"]
  }
}

resource "kubernetes_secret_v1" "firecrawl_gitlab_registry" {
  depends_on = [module.namespace["firecrawl"]]

  metadata {
    name      = "firecrawl-gitlab-registry"
    namespace = local.firecrawl_ns
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.firecrawl_registry_host) = {
          username = local.firecrawl_registry_user
          password = local.firecrawl_registry_pass
          auth     = base64encode("${local.firecrawl_registry_user}:${local.firecrawl_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_persistent_volume_claim_v1" "firecrawl_redis_data" {
  depends_on = [module.namespace["firecrawl"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "firecrawl-redis-data"
    namespace = local.firecrawl_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "2Gi" }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_persistent_volume_claim_v1" "firecrawl_postgres_data" {
  depends_on = [module.namespace["firecrawl"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "firecrawl-postgres-data"
    namespace = local.firecrawl_ns
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name

    resources {
      requests = { storage = "10Gi" }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubectl_manifest" "firecrawl_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.firecrawl_cnpg_app,
    kubernetes_secret_v1.firecrawl_gitlab_registry,
    kubernetes_service_v1.db_backup_sidecar_postgres["firecrawl"],
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.firecrawl_cnpg_cluster
      namespace = local.firecrawl_ns
    }
    spec = {
      instances             = 1
      imageName             = local.firecrawl_cnpg_image
      imagePullSecrets      = [{ name = kubernetes_secret_v1.firecrawl_gitlab_registry.metadata[0].name }]
      postgresUID           = 999
      postgresGID           = 999
      affinity              = { nodeSelector = { "kubernetes.io/arch" = "amd64" } }
      primaryUpdateMethod   = "restart"
      nodeMaintenanceWindow = { reusePVC = true }
      storage = {
        size         = "30Gi"
        storageClass = local.cnpg_storage_class
      }
      postgresql = {
        shared_preload_libraries = ["pg_cron"]
        parameters = {
          "cron.database_name" = "postgres"
          max_wal_size         = "2GB"
          shared_buffers       = "512MB"
          wal_compression      = "on"
        }
      }
      plugins = local.cnpg_plugin_specs["firecrawl"]
      bootstrap = {
        initdb = {
          database = "postgres"
          owner    = local.firecrawl_db_user
          secret   = { name = kubernetes_secret_v1.firecrawl_cnpg_app.metadata[0].name }
          import = {
            type      = "microservice"
            databases = ["postgres"]
            source    = { externalCluster = "firecrawl-source" }
          }
        }
      }
      externalClusters = [{
        name = "firecrawl-source"
        connectionParameters = {
          host    = local.firecrawl_db_source_service
          user    = local.firecrawl_db_user
          dbname  = "postgres"
          sslmode = "disable"
        }
        password = {
          name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
          key  = "DATABASE_PASSWORD"
        }
      }]
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "firecrawl" {
  depends_on = [
    kubectl_manifest.firecrawl_cnpg_cluster,
    kubernetes_secret_v1.firecrawl_env,
    kubernetes_service_v1.searxng,
  ]

  metadata {
    name      = "firecrawl"
    namespace = local.firecrawl_ns
    labels    = local.firecrawl_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.firecrawl_labels
    }

    template {
      metadata {
        labels = local.firecrawl_labels
      }

      spec {
        enable_service_links = false

        container {
          name    = "redis"
          image   = local.firecrawl_redis_image
          command = ["redis-server", "--bind", "0.0.0.0"]

          port {
            container_port = 6379
            name           = "redis"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        container {
          name  = "rabbitmq"
          image = local.firecrawl_rabbitmq_image

          port {
            container_port = 5672
            name           = "amqp"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
        }

        container {
          name  = "playwright"
          image = local.firecrawl_playwright_image

          port {
            container_port = local.firecrawl_playwright_port
            name           = "playwright"
          }

          env {
            name  = "PORT"
            value = tostring(local.firecrawl_playwright_port)
          }

          env {
            name  = "MAX_CONCURRENT_PAGES"
            value = "10"
          }

          env {
            name  = "PROXY_SERVER"
            value = "socks5://${var.rotating_proxy_addr}"
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "4000m"
              memory = "4Gi"
            }
          }
        }

        container {
          name    = "api"
          image   = local.firecrawl_image
          command = ["node", "dist/src/harness.js", "--start-docker"]

          port {
            container_port = local.firecrawl_api_port
            name           = "api"
          }

          env {
            name  = "HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "ENV"
            value = "local"
          }

          env {
            name  = "PORT"
            value = tostring(local.firecrawl_api_port)
          }

          env {
            name  = "EXTRACT_WORKER_PORT"
            value = "3004"
          }

          env {
            name  = "WORKER_PORT"
            value = "3005"
          }

          env {
            name  = "NUQ_WORKER_START_PORT"
            value = "3100"
          }

          env {
            name  = "NUM_WORKERS_PER_QUEUE"
            value = "8"
          }

          env {
            name  = "NODE_OPTIONS"
            value = "--max-old-space-size=6144"
          }

          env {
            name = "DATABASE_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "DATABASE_PASSWORD"
              }
            }
          }

          env {
            name = "BULL_AUTH_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "BULL_AUTH_KEY"
              }
            }
          }

          env {
            name = "TEST_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "TEST_API_KEY"
              }
            }
          }

          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }

          env {
            name  = "REDIS_URL"
            value = "redis://localhost:6379"
          }

          env {
            name  = "REDIS_RATE_LIMIT_URL"
            value = "redis://localhost:6379"
          }

          env {
            name  = "PLAYWRIGHT_MICROSERVICE_URL"
            value = "http://localhost:${local.firecrawl_playwright_port}/scrape"
          }

          env {
            name  = "NUQ_DATABASE_URL"
            value = "postgres://${local.firecrawl_db_user}:$(DATABASE_PASSWORD)@${local.firecrawl_db_service}:${local.firecrawl_postgres_port}/postgres"
          }

          env {
            name  = "NUQ_RABBITMQ_URL"
            value = "amqp://localhost:5672"
          }

          env {
            name  = "USE_DB_AUTHENTICATION"
            value = "false"
          }

          env {
            name = "OPENAI_BASE_URL"
            # Cluster DNS, not the LAN hairpin — required by the egress policy
            # below and per namespace-strategy §8.2 hairpin conversion.
            value = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
          }

          env {
            name  = "MODEL_NAME"
            value = "aether/qwen3:8b"
          }

          env {
            name  = "MODEL_EMBEDDING_NAME"
            value = "aether/qwen3-embedding:4b"
          }

          env {
            name  = "LOGGING_LEVEL"
            value = "debug"
          }

          env {
            name  = "SEARXNG_ENDPOINT"
            value = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.searxng_ns}.svc.cluster.local:${local.searxng_port}"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "3Gi"
            }
            limits = {
              cpu    = "4000m"
              memory = "8Gi"
            }
          }

          readiness_probe {
            tcp_socket {
              port = local.firecrawl_api_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        container {
          name    = "mcp"
          image   = local.firecrawl_mcp_image
          command = ["npx", "-y", "firecrawl-mcp"]

          port {
            container_port = local.firecrawl_mcp_port
            name           = "mcp"
          }

          env {
            name  = "PORT"
            value = tostring(local.firecrawl_mcp_port)
          }

          env {
            name  = "HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "HTTP_STREAMABLE_SERVER"
            value = "true"
          }

          env {
            name = "FIRECRAWL_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.firecrawl_env.metadata[0].name
                key  = "FIRECRAWL_API_KEY"
              }
            }
          }

          env {
            name = "FIRECRAWL_API_URL"
            # The API container lives in this same pod — localhost, not the LAN
            # hairpin (which the egress policy below deliberately blocks).
            value = "http://localhost:${local.firecrawl_api_port}"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

      }
    }
  }


  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service_v1" "firecrawl" {
  metadata {
    name      = "firecrawl"
    namespace = local.firecrawl_ns
    labels    = local.firecrawl_labels
  }

  spec {
    selector = local.firecrawl_labels

    port {
      port        = local.firecrawl_api_port
      target_port = local.firecrawl_api_port
      name        = "api"
    }

    port {
      port        = local.firecrawl_mcp_port
      target_port = local.firecrawl_mcp_port
      name        = "mcp"
    }
  }
}

# =============================================================================
# HTTPRoutes - Gateway API
# =============================================================================

resource "kubernetes_manifest" "firecrawl_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.firecrawl]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "firecrawl"
      namespace = local.firecrawl_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.firecrawl_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.firecrawl.metadata[0].name
          port = local.firecrawl_api_port
        }]
      }]
    }
  }
}

resource "kubernetes_manifest" "firecrawl_mcp_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.firecrawl]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "firecrawl-mcp"
      namespace = local.firecrawl_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.firecrawl_mcp_host]
      rules = [{
        backendRefs = [{
          name = kubernetes_service_v1.firecrawl.metadata[0].name
          port = local.firecrawl_mcp_port
        }]
      }]
    }
  }
}

# =============================================================================
# Egress boundary (answer-engine plan, companion MR 2)
# =============================================================================
# Firecrawl scrapes untrusted, attacker-suggested URLs, so the scraper workload
# (app=firecrawl: api/worker plus its sidecar redis/playwright containers) is
# the authoritative SSRF boundary for consumers like orion: internet-only
# egress — no RFC1918/link-local/loopback destinations — plus its declared
# in-cluster dependencies (own-namespace pods, searxng, litellm). The boundary
# deliberately excludes the CNPG cluster and db-backup pods: barman WAL
# archiving and pg_dump uploads target the internal SeaweedFS S3 endpoint
# (10.0.2.2), which the private-range except list would deny (broke backups on
# 2026-07-11 when this policy was namespace-wide via endpointSelector {}).
# The cluster baseline CCNP keeps DNS and kube-apiserver reachable under
# default-deny (Cilium policies union). Rollback: revert this resource and
# re-apply.
resource "kubernetes_manifest" "firecrawl_egress_boundary" {
  depends_on = [helm_release.cilium, module.namespace["firecrawl"]]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "firecrawl-egress-boundary"
      namespace = local.firecrawl_ns
    }
    spec = {
      endpointSelector = {
        matchLabels = local.firecrawl_labels
      }
      enableDefaultDeny = {
        ingress = false
        egress  = true
      }
      egress = [
        {
          # The scrape surface: the public internet, explicitly excluding
          # private, link-local (cloud metadata), and loopback ranges.
          toCIDRSet = [{
            cidr = "0.0.0.0/0"
            except = [
              "10.0.0.0/8",
              "172.16.0.0/12",
              "192.168.0.0/16",
              "169.254.0.0/16",
              "127.0.0.0/8",
            ]
          }]
        },
        {
          # Same-namespace: CNPG postgres, redis, playwright.
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.firecrawl_ns
            }
          }]
        },
        {
          # SEARXNG_ENDPOINT (deep-research search).
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
          # OPENAI_BASE_URL (LLM extraction) via cluster DNS.
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.litellm_ns
            }
          }]
          toPorts = [{
            ports = [{ port = tostring(local.litellm_port), protocol = "TCP" }]
          }]
        },
      ]
    }
  }
}
