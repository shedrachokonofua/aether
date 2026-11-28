# =============================================================================
# Nix Binary Cache — ncps (pull-through proxy) + Attic (private push cache)
# =============================================================================
# Both services run on the ARM64 pool, store immutable NAR/chunk blobs in
# SeaweedFS S3 (Smith's ZFS HDD array — zero Ceph NVMe write amplification),
# and share a small CNPG Postgres cluster on Ceph RBD for metadata.
#
# - ncps:  https://nix-cache.home.shdr.ch (in-cluster: http://ncps.nix-cache.svc.cluster.local:8501)
#          Pull-through proxy for cache.nixos.org and nix-community.cachix.org.
# - Attic: https://attic.home.shdr.ch     (in-cluster: http://attic.nix-cache.svc.cluster.local:8080)
#          Pushable private binary cache with FastCDC chunk deduplication.
#
# After apply, push the SeaweedFS S3 identities:
#   task seaweedfs:s3-identities:deploy

locals {
  nix_cache_namespace   = module.namespace["nix-cache"].name
  nix_cache_s3_endpoint = "https://s3.seaweed.home.shdr.ch"
  nix_cache_s3_region   = "us-east-1"

  ncps_host   = "nix-cache.home.shdr.ch"
  ncps_bucket = "nix-ncps"
  ncps_port   = 8501
  ncps_image  = "ghcr.io/kalbasit/ncps:v0.10.1@sha256:75fe26ea14bc35d336eca877a2e94a768d30631f415198242bbf1e5203f26a47"

  attic_host   = "attic.home.shdr.ch"
  attic_bucket = "nix-attic"
  attic_port   = 8080
  attic_image  = "ghcr.io/zhaofengli/attic:latest@sha256:18574aba70fc89d2b695273fbe2e7b2f8ad7e8e786b4cc535124fbe14bada1d0"

  nix_cache_cnpg = "nix-cache-cnpg"
  attic_db_name  = "attic"
  attic_db_user  = "attic"
  ncps_db_name   = "ncps"
  ncps_db_user   = "ncps"

  nix_cache_labels = {
    "app.kubernetes.io/part-of"    = "nix-cache"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
  ncps_labels  = merge(local.nix_cache_labels, { "app.kubernetes.io/name" = "ncps" })
  attic_labels = merge(local.nix_cache_labels, { "app.kubernetes.io/name" = "attic" })
}

# --- Generated credentials ----------------------------------------------------

resource "random_password" "nix_cache_attic_db_password" {
  length  = 32
  special = false
}

resource "random_password" "nix_cache_ncps_db_password" {
  length  = 32
  special = false
}

resource "random_password" "nix_cache_s3_access_key" {
  length  = 20
  special = false
}

resource "random_password" "nix_cache_s3_secret_key" {
  length  = 40
  special = false
}

resource "random_password" "attic_jwt_secret" {
  length  = 64
  special = false
}

# --- SeaweedFS S3 buckets -----------------------------------------------------

resource "terraform_data" "nix_cache_buckets" {
  triggers_replace = [join(",", [local.ncps_bucket, local.attic_bucket])]

  provisioner "local-exec" {
    command = <<-EOT
      for bucket in $S3_BUCKETS; do
        aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 || \
          aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$bucket" >/dev/null
      done
    EOT
    environment = {
      AWS_ACCESS_KEY_ID         = var.secrets["seaweedfs.s3_admin_access_key"]
      AWS_SECRET_ACCESS_KEY     = var.secrets["seaweedfs.s3_admin_secret_key"]
      AWS_DEFAULT_REGION        = local.nix_cache_s3_region
      AWS_EC2_METADATA_DISABLED = "true"
      S3_ENDPOINT               = local.nix_cache_s3_endpoint
      S3_BUCKETS                = "${local.ncps_bucket} ${local.attic_bucket}"
    }
  }
}

# --- Postgres (CNPG, shared metadata DB for Attic + ncps) ---------------------

resource "kubernetes_secret_v1" "nix_cache_attic_db" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "nix-cache-attic-db"
    namespace = local.nix_cache_namespace
    labels    = local.attic_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.attic_db_user
    password = random_password.nix_cache_attic_db_password.result
  }
}

resource "kubernetes_secret_v1" "nix_cache_ncps_db" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "nix-cache-ncps-db"
    namespace = local.nix_cache_namespace
    labels    = local.ncps_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.ncps_db_user
    password = random_password.nix_cache_ncps_db_password.result
  }
}

resource "kubectl_manifest" "nix_cache_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubectl_manifest.cnpg_barman_object_store["nix-cache"],
    kubernetes_secret_v1.nix_cache_attic_db,
    kubernetes_secret_v1.nix_cache_ncps_db,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.nix_cache_cnpg
      namespace = local.nix_cache_namespace
      labels    = merge(local.nix_cache_labels, { "aether.sh/arm-ok" = "true" })
    }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      imageName            = "ghcr.io/cloudnative-pg/postgresql:17.9"
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["nix-cache"]
      bootstrap = {
        initdb = {
          database = local.attic_db_name
          owner    = local.attic_db_user
          secret   = { name = kubernetes_secret_v1.nix_cache_attic_db.metadata[0].name }
        }
      }
      managed = {
        roles = [{
          name           = local.ncps_db_user
          ensure         = "present"
          login          = true
          passwordSecret = { name = kubernetes_secret_v1.nix_cache_ncps_db.metadata[0].name }
        }]
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubectl_manifest" "nix_cache_ncps_database" {
  depends_on = [kubectl_manifest.nix_cache_cnpg_cluster]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Database"
    metadata = {
      name      = "ncps-db"
      namespace = local.nix_cache_namespace
      labels    = local.ncps_labels
    }
    spec = {
      name                  = local.ncps_db_name
      owner                 = local.ncps_db_user
      cluster               = { name = local.nix_cache_cnpg }
      databaseReclaimPolicy = "retain"
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# --- ncps (pull-through proxy) ------------------------------------------------

resource "kubernetes_config_map_v1" "ncps_config" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "ncps-config"
    namespace = local.nix_cache_namespace
    labels    = local.ncps_labels
  }

  data = {
    "config.yaml" = yamlencode({
      log = { level = "info" }
      analytics = {
        reporting = { enabled = false }
      }
      opentelemetry = {
        enabled  = true
        grpc-url = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4317"
      }
      prometheus = { enabled = true }
      server     = { addr = ":${local.ncps_port}" }
      cache = {
        hostname     = local.ncps_host
        max-size     = "200G"
        sign-narinfo = true
        temp-path    = "/tmp"
        lru = {
          schedule = "0 3 * * *"
          timezone = "America/Toronto"
        }
        storage = {
          s3 = {
            bucket           = local.ncps_bucket
            endpoint         = local.nix_cache_s3_endpoint
            region           = local.nix_cache_s3_region
            force-path-style = true
          }
        }
        upstream = {
          urls = [
            "https://cache.nixos.org",
            "https://nix-community.cachix.org",
          ]
          public-keys = [
            "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=",
            "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=",
          ]
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "ncps_env" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "ncps-env"
    namespace = local.nix_cache_namespace
    labels    = local.ncps_labels
  }

  type = "Opaque"
  data = {
    CACHE_DATABASE_URL                 = "postgresql://${local.ncps_db_user}:${random_password.nix_cache_ncps_db_password.result}@${local.nix_cache_cnpg}-rw.${local.nix_cache_namespace}.svc.cluster.local:5432/${local.ncps_db_name}?sslmode=disable"
    CACHE_STORAGE_S3_ACCESS_KEY_ID     = random_password.nix_cache_s3_access_key.result
    CACHE_STORAGE_S3_SECRET_ACCESS_KEY = random_password.nix_cache_s3_secret_key.result
    HOME                               = "/tmp"
    XDG_CONFIG_HOME                    = "/tmp"
  }
}

resource "kubernetes_deployment_v1" "ncps" {
  depends_on = [
    kubernetes_config_map_v1.ncps_config,
    kubernetes_secret_v1.ncps_env,
    kubectl_manifest.nix_cache_ncps_database,
    terraform_data.nix_cache_buckets,
  ]

  wait_for_rollout = false

  metadata {
    name      = "ncps"
    namespace = local.nix_cache_namespace
    labels    = local.ncps_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.ncps_labels
    }

    template {
      metadata {
        labels = merge(local.ncps_labels, { "aether.sh/arm-ok" = "true" })
        annotations = {
          "aether.shdr.ch/config-sha" = sha256(kubernetes_config_map_v1.ncps_config.data["config.yaml"])
          "aether.shdr.ch/env-sha"    = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.ncps_env.data)))
        }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }

        init_container {
          name    = "migrate"
          image   = local.ncps_image
          command = ["/bin/ncps"]
          args    = ["migrate", "up"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.ncps_env.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        container {
          name    = "ncps"
          image   = local.ncps_image
          command = ["/bin/ncps"]
          args    = ["--config", "/etc/ncps/config.yaml", "serve"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.ncps_env.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          port {
            name           = "http"
            container_port = local.ncps_port
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 10
            timeout_seconds       = 5
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 20
            timeout_seconds       = 5
            failure_threshold     = 6
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/ncps"
            read_only  = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.ncps_config.metadata[0].name
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "4Gi"
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

resource "kubernetes_service_v1" "ncps" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "ncps"
    namespace = local.nix_cache_namespace
    labels    = local.ncps_labels
  }

  spec {
    selector = local.ncps_labels

    port {
      name        = "http"
      port        = local.ncps_port
      target_port = "http"
    }
  }
}

resource "kubernetes_manifest" "ncps_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.ncps]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "ncps"
      namespace = local.nix_cache_namespace
      labels    = local.ncps_labels
    }
    spec = {
      parentRefs = [{
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "http"
      }]
      hostnames = [local.ncps_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.ncps.metadata[0].name
          port = local.ncps_port
        }]
      }]
    }
  }
}

# --- Attic (private pushable binary cache) ------------------------------------

resource "kubernetes_config_map_v1" "attic_config" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "attic-config"
    namespace = local.nix_cache_namespace
    labels    = local.attic_labels
  }

  data = {
    "server.toml" = <<-EOT
      listen = "[::]:${local.attic_port}"
      allowed-hosts = [
        "${local.attic_host}",
        "attic.${local.nix_cache_namespace}.svc.cluster.local",
        "attic.${local.nix_cache_namespace}.svc.cluster.local:${local.attic_port}",
        "attic.${local.nix_cache_namespace}.svc",
        "attic.${local.nix_cache_namespace}.svc:${local.attic_port}",
        "attic",
        "attic:${local.attic_port}",
      ]
      api-endpoint = "https://${local.attic_host}/"
      require-proof-of-possession = true

      [database]
      heartbeat = true

      [storage]
      type = "s3"
      region = "${local.nix_cache_s3_region}"
      bucket = "${local.attic_bucket}"
      endpoint = "${local.nix_cache_s3_endpoint}"

      [chunking]
      nar-size-threshold = 65536
      min-size = 16384
      avg-size = 65536
      max-size = 262144

      [compression]
      type = "zstd"

      [garbage-collection]
      interval = "12 hours"
      default-retention-period = "90 days"
    EOT
  }
}

resource "kubernetes_secret_v1" "attic_env" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "attic-env"
    namespace = local.nix_cache_namespace
    labels    = local.attic_labels
  }

  type = "Opaque"
  data = {
    ATTIC_SERVER_DATABASE_URL              = "postgresql://${local.attic_db_user}:${random_password.nix_cache_attic_db_password.result}@${local.nix_cache_cnpg}-rw.${local.nix_cache_namespace}.svc.cluster.local:5432/${local.attic_db_name}"
    ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64 = base64encode(random_password.attic_jwt_secret.result)
    AWS_ACCESS_KEY_ID                      = random_password.nix_cache_s3_access_key.result
    AWS_SECRET_ACCESS_KEY                  = random_password.nix_cache_s3_secret_key.result
    AWS_REGION                             = local.nix_cache_s3_region
    AWS_EC2_METADATA_DISABLED              = "true"
  }
}

resource "kubernetes_deployment_v1" "attic" {
  depends_on = [
    kubernetes_config_map_v1.attic_config,
    kubernetes_secret_v1.attic_env,
    kubectl_manifest.nix_cache_cnpg_cluster,
    terraform_data.nix_cache_buckets,
  ]

  wait_for_rollout = false

  metadata {
    name      = "attic"
    namespace = local.nix_cache_namespace
    labels    = local.attic_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.attic_labels
    }

    template {
      metadata {
        labels = merge(local.attic_labels, { "aether.sh/arm-ok" = "true" })
        annotations = {
          "aether.shdr.ch/config-sha" = sha256(kubernetes_config_map_v1.attic_config.data["server.toml"])
          "aether.shdr.ch/env-sha"    = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.attic_env.data)))
        }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          seccomp_profile { type = "RuntimeDefault" }
        }

        container {
          name  = "attic"
          image = local.attic_image
          args  = ["-f", "/etc/attic/server.toml", "--mode", "monolithic"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.attic_env.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }

          port {
            name           = "http"
            container_port = local.attic_port
          }

          readiness_probe {
            tcp_socket {
              port = "http"
            }
            initial_delay_seconds = 5
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
            limits   = { cpu = "1", memory = "1Gi" }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/attic"
            read_only  = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.attic_config.metadata[0].name
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "4Gi"
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

resource "kubernetes_service_v1" "attic" {
  depends_on = [module.namespace["nix-cache"]]

  metadata {
    name      = "attic"
    namespace = local.nix_cache_namespace
    labels    = local.attic_labels
  }

  spec {
    selector = local.attic_labels

    port {
      name        = "http"
      port        = local.attic_port
      target_port = "http"
    }
  }
}

resource "kubernetes_manifest" "attic_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.attic]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "attic"
      namespace = local.nix_cache_namespace
      labels    = local.attic_labels
    }
    spec = {
      parentRefs = [{
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "http"
      }]
      hostnames = [local.attic_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.attic.metadata[0].name
          port = local.attic_port
        }]
      }]
    }
  }
}
