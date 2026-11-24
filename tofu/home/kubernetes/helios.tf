# =============================================================================
# Helios — car-sales storefront and admin panel
# =============================================================================
# Sibling repo /Users/shdrch/projects/helios
# (ssh://git@ssh.gitlab.home.shdr.ch:2222/so/helios.git), built by Cicada from
# its docs/spec.md. That repo owns the code, the image and CI; this file owns
# every cluster object around it, sized to the spec's "Deployment contract":
# namespace contract (namespace_contracts.tf), CNPG database, photo bucket and
# its SeaweedFS identity (db_backups.tf seaweedfs-s3.json), secrets, registry
# pull identity, Deployment, Service and route.
#
# Exposure: https://helios.shdr.ch. Cloudflare's `*` record → public gateway →
# home gateway Caddy :9443 `@helios`, which authenticates every request
# through oauth2-proxy (Keycloak realm `aether`, client `oauth2-proxy`,
# keycloak.tf) and forwards X-Auth-Request-User/-Email with Host
# helios.home.shdr.ch to the Gateway. The app has no login of its own
# (so/helios docs/decisions.md D-2).
#
# Rollout: so/helios main publishes :latest after its gate passes; Keel polls
# the tag and force-updates the Deployment. helios_replicas stays 0 until the
# first image exists (so no ImagePullBackOff alert), then 1.
#
# After apply, push the new SeaweedFS identity:
#   task seaweedfs:s3-identities:deploy

locals {
  helios_namespace     = module.namespace["helios"].name
  helios_internal_host = "helios.home.shdr.ch"
  helios_public_url    = "https://helios.shdr.ch"
  helios_image         = "${local.gitlab_registry_host}/so/helios:latest"
  helios_port          = 8080
  helios_replicas      = 0
  helios_labels = {
    "app.kubernetes.io/name"       = "helios"
    "app.kubernetes.io/part-of"    = "helios"
    "app.kubernetes.io/managed-by" = "opentofu"
  }

  helios_cnpg          = "helios-cnpg"
  helios_database      = "helios"
  helios_database_user = "helios"

  helios_s3_endpoint  = "https://s3.seaweed.home.shdr.ch"
  helios_photo_bucket = "helios-photos"

  # so/helios D-4: Nigerian naira.
  helios_currency = "NGN"
}

# --- Generated credentials ----------------------------------------------------

resource "random_password" "helios_database_password" {
  length  = 32
  special = false
}

resource "random_password" "helios_s3_access_key" {
  length  = 20
  special = false
}

resource "random_password" "helios_s3_secret_key" {
  length  = 40
  special = false
}

# basic-auth: CNPG bootstrap reads username/password for the database owner.
resource "kubernetes_secret_v1" "helios_cnpg_app" {
  depends_on = [module.namespace["helios"]]

  metadata {
    name      = "helios-cnpg-app"
    namespace = local.helios_namespace
    labels    = local.helios_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.helios_database_user
    password = random_password.helios_database_password.result
  }
}

# Environment names are the so/helios spec's deployment contract.
resource "kubernetes_secret_v1" "helios_env" {
  depends_on = [module.namespace["helios"]]

  metadata {
    name      = "helios-env"
    namespace = local.helios_namespace
    labels    = local.helios_labels
  }

  type = "Opaque"
  data = {
    DATABASE_URL         = "postgresql://${local.helios_database_user}:${random_password.helios_database_password.result}@${local.helios_cnpg}-rw.${local.helios_namespace}.svc.cluster.local:5432/${local.helios_database}"
    HELIOS_AUTH          = "proxy"
    HELIOS_PUBLIC_URL    = local.helios_public_url
    HELIOS_CURRENCY      = local.helios_currency
    S3_ENDPOINT          = local.helios_s3_endpoint
    S3_BUCKET            = local.helios_photo_bucket
    S3_REGION            = "us-east-1"
    S3_ACCESS_KEY_ID     = random_password.helios_s3_access_key.result
    S3_SECRET_ACCESS_KEY = random_password.helios_s3_secret_key.result
  }
}

# --- GitLab registry pull identity -------------------------------------------

resource "kubernetes_secret_v1" "helios_registry" {
  depends_on = [module.namespace["helios"]]

  metadata {
    name      = "helios-gitlab-registry"
    namespace = local.helios_namespace
    labels    = local.helios_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.gitlab_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

# --- Photo bucket ------------------------------------------------------------
# Private: the app serves photos through its own routes (so/helios D-3). The
# scoped identity is in db_backups.tf's seaweedfs-s3.json.

resource "terraform_data" "helios_buckets" {
  triggers_replace = [local.helios_photo_bucket]

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
      S3_ENDPOINT               = local.helios_s3_endpoint
      S3_BUCKET                 = local.helios_photo_bucket
    }
  }
}

# --- Postgres (CNPG) ---------------------------------------------------------
# WAL archiving and daily base backups go to SeaweedFS (cnpg_backups.tf).

resource "kubectl_manifest" "helios_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubectl_manifest.cnpg_barman_object_store["helios"],
    kubernetes_secret_v1.helios_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.helios_cnpg
      namespace = local.helios_namespace
      labels    = merge(local.helios_labels, { "aether.sh/arm-ok" = "true" })
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
      plugins = local.cnpg_plugin_specs["helios"]
      bootstrap = {
        initdb = {
          database = local.helios_database
          owner    = local.helios_database_user
          secret   = { name = kubernetes_secret_v1.helios_cnpg_app.metadata[0].name }
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# --- Application -------------------------------------------------------------

resource "kubernetes_deployment_v1" "helios" {
  depends_on = [
    kubernetes_secret_v1.helios_env,
    kubernetes_secret_v1.helios_registry,
    kubectl_manifest.helios_cnpg_cluster,
    terraform_data.helios_buckets,
  ]

  wait_for_rollout = false

  metadata {
    name      = "helios"
    namespace = local.helios_namespace
    labels    = local.helios_labels
    annotations = {
      # Follow :latest from so/helios main (published only after its gate).
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    replicas = local.helios_replicas

    selector {
      match_labels = local.helios_labels
    }

    template {
      metadata {
        labels = local.helios_labels
        annotations = {
          "aether.shdr.ch/env-sha" = nonsensitive(sha256(jsonencode(kubernetes_secret_v1.helios_env.data)))
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

        image_pull_secrets {
          name = kubernetes_secret_v1.helios_registry.metadata[0].name
        }

        container {
          name              = "helios"
          image             = local.helios_image
          image_pull_policy = "Always"

          env {
            name  = "PORT"
            value = tostring(local.helios_port)
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.helios_env.metadata[0].name
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
            container_port = local.helios_port
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
            limits   = { cpu = "1", memory = "512Mi" }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "256Mi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].priority_class_name,
      # Keel's rollouts.
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
      metadata[0].annotations["kubernetes.io/change-cause"],
    ]
  }
}

resource "kubernetes_service_v1" "helios" {
  depends_on = [module.namespace["helios"]]

  metadata {
    name      = "helios"
    namespace = local.helios_namespace
    labels    = local.helios_labels
  }

  spec {
    selector = local.helios_labels

    port {
      name        = "http"
      port        = local.helios_port
      target_port = "http"
    }
  }
}

# The internal name only. The public, Keycloak-protected name is
# helios.shdr.ch, rewritten to this Host by the home gateway's :9443 handler.
resource "kubernetes_manifest" "helios_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.helios]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "helios"
      namespace = local.helios_namespace
      labels    = local.helios_labels
    }
    spec = {
      parentRefs = [{
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "http"
      }]
      hostnames = [local.helios_internal_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = kubernetes_service_v1.helios.metadata[0].name
          port = local.helios_port
        }]
      }]
    }
  }
}
