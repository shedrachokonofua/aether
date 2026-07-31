# =============================================================================
# Buzz — self-hosted Nostr relay workspace (github.com/block/buzz)
# =============================================================================
# Single relay binary serving WebSocket + REST + web UI, backed by:
#   - postgres  (CNPG + barman backups via cnpg_backup_targets["buzz"])
#   - redis     (per-app Deployment, pubsub fan-out only; no persistence)
#   - S3        (SeaweedFS bucket "buzz-media", identity in db_backups.tf)
#
# Chart: oci://ghcr.io/block/buzz/charts/buzz (production profile —
# existingSecret, no bundled services). Routing: HTTPRoute on main-gateway,
# TLS terminated at the home-gateway Caddy wildcard (*.home.shdr.ch).
#
# The relay owner keypair was generated out-of-band; the pubkey lives below
# and the private key is in SOPS (secrets/secrets.yml:
# buzz.owner_private_key / buzz.owner_pubkey). Rotating the owner key changes
# nothing for the relay identity itself — the relay's own identity is
# BUZZ_RELAY_PRIVATE_KEY in the buzz-relay Secret (tofu state).

locals {
  buzz_namespace     = module.namespace["buzz"].name
  buzz_host          = "buzz.home.shdr.ch"
  buzz_chart_version = "0.1.7"
  # Chart appVersion 0.1.0 predates the relay's embedded sqlx startup
  # migrations (it dies on a fresh database: "relation events does not
  # exist"). Pin the image to an immutable main-branch build that has
  # them; keep roughly in step with the chart.
  buzz_image_tag        = "sha-23f0c26"
  buzz_owner_pubkey     = "159d4e8f1481c71a8a56c219ffac61f17056d2b631ad1e2a3efaf642655a92f2"
  buzz_cnpg             = "buzz-cnpg"
  buzz_database         = "buzz"
  buzz_database_user    = "buzz"
  buzz_database_service = "${local.buzz_cnpg}-rw.${local.buzz_namespace}.svc.cluster.local"
  buzz_redis_port       = 6379
  buzz_redis_service    = "buzz-redis.${local.buzz_namespace}.svc.cluster.local"
  buzz_redis_image      = "docker.io/redis:7.4-alpine"
  buzz_media_endpoint   = "https://s3.seaweed.home.shdr.ch"
  buzz_media_bucket     = "buzz-media"
  buzz_labels           = { app = "buzz" }
  buzz_redis_labels     = { app = "buzz-redis" }
}

resource "random_bytes" "buzz_relay_private_key" {
  length = 32
}

resource "random_password" "buzz_database_password" {
  length  = 32
  special = false
}

resource "random_password" "buzz_git_hook_hmac_secret" {
  length  = 48
  special = false
}

resource "random_password" "buzz_media_s3_access_key" {
  length  = 20
  special = false
}

resource "random_password" "buzz_media_s3_secret_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "buzz_cnpg_app" {
  depends_on = [module.namespace["buzz"]]

  metadata {
    name      = "buzz-cnpg-app"
    namespace = local.buzz_namespace
    labels    = local.buzz_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.buzz_database_user
    password = random_password.buzz_database_password.result
  }
}

# Consumed by the chart via secrets.existingSecret. Key names are the env vars
# the relay expects (see deploy/charts/buzz/templates/deployment.yaml).
resource "kubernetes_secret_v1" "buzz_relay" {
  depends_on = [module.namespace["buzz"]]

  metadata {
    name      = "buzz-relay"
    namespace = local.buzz_namespace
    labels    = local.buzz_labels
  }

  type = "Opaque"
  data = {
    BUZZ_RELAY_PRIVATE_KEY    = random_bytes.buzz_relay_private_key.hex
    BUZZ_GIT_HOOK_HMAC_SECRET = random_password.buzz_git_hook_hmac_secret.result
    DATABASE_URL              = "postgresql://${local.buzz_database_user}:${random_password.buzz_database_password.result}@${local.buzz_database_service}:5432/${local.buzz_database}?sslmode=disable"
    REDIS_URL                 = "redis://${local.buzz_redis_service}:${local.buzz_redis_port}"
    BUZZ_S3_ACCESS_KEY        = random_password.buzz_media_s3_access_key.result
    BUZZ_S3_SECRET_KEY        = random_password.buzz_media_s3_secret_key.result
  }
}

# =============================================================================
# Redis (buzz-pubsub fan-out; no persistence — matches dawarich/nextcloud)
# =============================================================================

resource "kubernetes_deployment_v1" "buzz_redis" {
  depends_on = [module.namespace["buzz"]]

  metadata {
    name      = "buzz-redis"
    namespace = local.buzz_namespace
    labels    = local.buzz_redis_labels
  }

  spec {
    replicas = 1
    selector { match_labels = local.buzz_redis_labels }
    template {
      metadata { labels = local.buzz_redis_labels }
      spec {
        enable_service_links = false
        container {
          name    = "redis"
          image   = local.buzz_redis_image
          command = ["redis-server", "--save", "", "--appendonly", "no"]
          port { container_port = local.buzz_redis_port }
          resources {
            requests = { cpu = "30m", memory = "32Mi" }
            limits   = { cpu = "300m", memory = "256Mi" }
          }
          readiness_probe {
            exec { command = ["redis-cli", "ping"] }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "buzz_redis" {
  depends_on = [kubernetes_deployment_v1.buzz_redis]

  metadata {
    name      = "buzz-redis"
    namespace = local.buzz_namespace
    labels    = local.buzz_redis_labels
  }

  spec {
    selector = local.buzz_redis_labels
    port {
      port        = local.buzz_redis_port
      target_port = local.buzz_redis_port
    }
  }
}

# =============================================================================
# Postgres (CNPG)
# =============================================================================

resource "kubectl_manifest" "buzz_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.buzz_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.buzz_cnpg
      namespace = local.buzz_namespace
      labels    = merge(local.buzz_labels, { "aether.sh/arm-ok" = "true" })
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:16.14"
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
      affinity = { nodeSelector = { "kubernetes.io/arch" = "amd64" } }
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["buzz"]
      bootstrap = {
        initdb = {
          database = local.buzz_database
          owner    = local.buzz_database_user
          secret   = { name = kubernetes_secret_v1.buzz_cnpg_app.metadata[0].name }
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# S3 media bucket (SeaweedFS; identity is provisioned in db_backups.tf and
# pushed to the filer by `task seaweedfs:s3-identities:deploy`)
# =============================================================================

resource "terraform_data" "buzz_media_bucket" {
  triggers_replace = [local.buzz_media_bucket]

  provisioner "local-exec" {
    command = <<-EOT
      aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 || \
        aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
    EOT
    environment = {
      AWS_ACCESS_KEY_ID         = var.secrets["seaweedfs.s3_admin_access_key"]
      AWS_SECRET_ACCESS_KEY     = var.secrets["seaweedfs.s3_admin_secret_key"]
      AWS_DEFAULT_REGION        = "us-east-1"
      AWS_EC2_METADATA_DISABLED = "true"
      S3_ENDPOINT               = local.buzz_media_endpoint
      S3_BUCKET                 = local.buzz_media_bucket
    }
  }
}

# =============================================================================
# Relay (Helm)
# =============================================================================

resource "helm_release" "buzz" {
  depends_on = [
    kubectl_manifest.buzz_cnpg_cluster,
    kubernetes_deployment_v1.buzz_redis,
    kubernetes_manifest.main_gateway,
    kubernetes_secret_v1.buzz_relay,
    terraform_data.buzz_media_bucket,
  ]

  name       = "buzz"
  repository = "oci://ghcr.io/block/buzz/charts"
  chart      = "buzz"
  namespace  = local.buzz_namespace
  version    = local.buzz_chart_version
  wait       = true
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    image = {
      tag = local.buzz_image_tag
    }

    relayUrl    = "wss://${local.buzz_host}"
    ownerPubkey = local.buzz_owner_pubkey

    secrets = {
      existingSecret = kubernetes_secret_v1.buzz_relay.metadata[0].name
    }

    # 0.1.7 schema allows only endpoint/bucket/accessKey/secretKey; the
    # chart default addressing style is path and the relay falls back to
    # its built-in AWS_REGION (us-east-1), which SeaweedFS accepts.
    s3 = {
      endpoint = local.buzz_media_endpoint
      bucket   = local.buzz_media_bucket
    }

    # Git scratch: per-pod emptyDir, not a PVC. Git ref/object state is
    # object-store-backed (Postgres + S3 are the sources of truth); the
    # volume is pure working space. An RWO PVC deadlocks rolling updates
    # (multi-attach) and adds nothing durable.
    persistence = {
      git = {
        enabled = false
        size    = "10Gi"
      }
    }

    httproute = {
      enabled = true
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.buzz_host]
    }
  })]
}

# Ingress policy for the relay pods: gateway + same-namespace only. Egress is
# unrestricted (baseline has no default-deny) so the relay can reach CNPG,
# Redis, and SeaweedFS.
resource "kubernetes_manifest" "buzz_relay_ingress" {
  depends_on = [
    helm_release.buzz,
    kubernetes_manifest.cilium_cluster_baseline_network,
  ]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "buzz-relay-ingress"
      namespace = local.buzz_namespace
    }
    spec = {
      endpointSelector = {
        matchLabels = {
          "app.kubernetes.io/instance"  = "buzz"
          "app.kubernetes.io/component" = "relay"
        }
      }
      ingress = [
        {
          fromEntities = ["ingress"]
          toPorts      = [{ ports = [{ port = "3000", protocol = "TCP" }] }]
        },
        {
          fromEndpoints = [{
            matchLabels = { "io.kubernetes.pod.namespace" = local.buzz_namespace }
          }]
          toPorts = [{ ports = [{ port = "3000", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
