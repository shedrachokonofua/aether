# =============================================================================
# Daimyo dev services — disposable Postgres, NATS and S3 for workspace tests
# =============================================================================
# The Coder workspace (namespace coder, pod daimyo-dev) used to run these
# three processes itself and sat at its memory limit. They live here instead,
# reachable by ClusterIP DNS from that pod. Nothing here is production: the
# daimyo-system CNPG cluster, its NATS and the daimyo-* buckets stay untouched,
# and this data is thrown away (backup=none, no Barman, emptyDir stores).
#
# Tests create a database per case, so the app role has CREATEDB. NATS has no
# auth. S3 credentials are fixed dev keys generated here; tests create buckets.

locals {
  daimyo_dev_ns = module.namespace["daimyo-dev"].name
  # Distinct from production's { app = "daimyo" } so a selector never matches both.
  daimyo_dev_labels = { app = "daimyo-dev" }
  daimyo_dev_pg     = "daimyo-dev-pg"
  daimyo_dev_db     = "daimyo"
  daimyo_dev_user   = "daimyo"
  # Same major as CI's postgres:17 service and production's chart image.
  # No arch pin: this image and the CNPG sidecars publish linux/arm64.
  daimyo_dev_pg_image = "ghcr.io/cloudnative-pg/postgresql:17.10"
  # CI runs nats-server 2.11 with -js and no auth; the official image's
  # 2.11 tag floats, so pin the patch CI's line is on.
  daimyo_dev_nats_image = "nats:2.11.8"
  # Same server as CI's rust-test service (rustfs/rustfs), pinned off :latest.
  daimyo_dev_s3_image = "rustfs/rustfs:1.0.0-rc.1"
}

resource "random_password" "daimyo_dev_postgres" {
  length  = 32
  special = false
}

resource "random_password" "daimyo_dev_s3_access_key" {
  length  = 20
  special = false
}

resource "random_password" "daimyo_dev_s3_secret_key" {
  length  = 40
  special = false
}

# --- Postgres ----------------------------------------------------------------

resource "kubernetes_secret_v1" "daimyo_dev_cnpg_app" {
  depends_on = [module.namespace["daimyo-dev"]]

  metadata {
    name      = "daimyo-dev-pg-app"
    namespace = local.daimyo_dev_ns
    labels    = local.daimyo_dev_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.daimyo_dev_user
    password = random_password.daimyo_dev_postgres.result
  }
}

resource "kubectl_manifest" "daimyo_dev_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.daimyo_dev_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.daimyo_dev_pg
      namespace = local.daimyo_dev_ns
      labels    = merge(local.daimyo_dev_labels, { "aether.sh/arm-ok" = "true" })
    }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      imageName            = local.daimyo_dev_pg_image
      # Dev data is disposable and the namespace backup contract is "none",
      # so there is no Barman plugin and no backup (Kyverno only requires one
      # when aether.shdr.ch/backup != none).
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "2", memory = "2Gi" }
      }
      postgresql = {
        parameters = {
          # A workspace's parallel tests each open a pool against their own
          # database; the chart default of 100 is too small for that.
          max_connections = "400"
        }
      }
      storage = {
        size         = "10Gi"
        storageClass = local.cnpg_storage_class
      }
      managed = {
        roles = [{
          name      = local.daimyo_dev_user
          ensure    = "present"
          login     = true
          createdb  = true
          superuser = false
          passwordSecret = {
            name = kubernetes_secret_v1.daimyo_dev_cnpg_app.metadata[0].name
          }
        }]
      }
      bootstrap = {
        initdb = {
          database = local.daimyo_dev_db
          owner    = local.daimyo_dev_user
          secret   = { name = kubernetes_secret_v1.daimyo_dev_cnpg_app.metadata[0].name }
        }
      }
    }
  })
}

# --- NATS (JetStream, no auth) ----------------------------------------------

resource "kubernetes_stateful_set_v1" "daimyo_dev_nats" {
  depends_on = [module.namespace["daimyo-dev"]]

  metadata {
    name      = "daimyo-dev-nats"
    namespace = local.daimyo_dev_ns
    labels    = local.daimyo_dev_labels
  }

  spec {
    service_name = "daimyo-dev-nats"
    replicas     = 1

    selector {
      match_labels = { app = "daimyo-dev-nats" }
    }

    template {
      metadata {
        labels = merge(local.daimyo_dev_labels, { app = "daimyo-dev-nats" })
      }
      spec {
        # Namespace tier sandbox enforces the restricted Pod Security profile.
        # The official image runs as 65532 when told to.
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          fs_group        = 65532
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "nats"
          image   = local.daimyo_dev_nats_image
          command = ["nats-server"]
          args    = ["-js", "-sd", "/data", "-m", "8222"]

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 65532
            run_as_group               = 65532
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }

          port {
            name           = "client"
            container_port = 4222
          }
          port {
            name           = "monitor"
            container_port = 8222
          }

          readiness_probe {
            http_get {
              path = "/healthz?js-enabled-only=true"
              port = 8222
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          volume_mount {
            name       = "jetstream"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }
        }

        volume {
          name = "jetstream"
          empty_dir {
            size_limit = "2Gi"
          }
        }
      }
    }
  }

  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

resource "kubernetes_service_v1" "daimyo_dev_nats" {
  depends_on = [kubernetes_stateful_set_v1.daimyo_dev_nats]

  metadata {
    name      = "daimyo-dev-nats"
    namespace = local.daimyo_dev_ns
    labels    = local.daimyo_dev_labels
  }

  spec {
    selector = { app = "daimyo-dev-nats" }
    port {
      name        = "client"
      port        = 4222
      target_port = 4222
    }
    type = "ClusterIP"
  }
}

# --- S3 (RustFS, the server CI's rust-test job uses) ------------------------

resource "kubernetes_secret_v1" "daimyo_dev_s3" {
  depends_on = [module.namespace["daimyo-dev"]]

  metadata {
    name      = "daimyo-dev-s3"
    namespace = local.daimyo_dev_ns
    labels    = local.daimyo_dev_labels
  }

  type = "Opaque"
  data = {
    AWS_ACCESS_KEY_ID     = random_password.daimyo_dev_s3_access_key.result
    AWS_SECRET_ACCESS_KEY = random_password.daimyo_dev_s3_secret_key.result
    AWS_DEFAULT_REGION    = "us-east-1"
  }
}

resource "kubernetes_stateful_set_v1" "daimyo_dev_s3" {
  depends_on = [kubernetes_secret_v1.daimyo_dev_s3]

  metadata {
    name      = "daimyo-dev-s3"
    namespace = local.daimyo_dev_ns
    labels    = local.daimyo_dev_labels
  }

  spec {
    service_name = "daimyo-dev-s3"
    replicas     = 1

    selector {
      match_labels = { app = "daimyo-dev-s3" }
    }

    template {
      metadata {
        labels = merge(local.daimyo_dev_labels, { app = "daimyo-dev-s3" })
      }
      spec {
        # The image runs as uid 10001 and writes its volume there. The
        # sandbox tier enforces the restricted Pod Security profile.
        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "rustfs"
          image = local.daimyo_dev_s3_image
          args  = ["/data"]

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 10001
            run_as_group               = 10001
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }
          env {
            name = "RUSTFS_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.daimyo_dev_s3.metadata[0].name
                key  = "AWS_ACCESS_KEY_ID"
              }
            }
          }
          env {
            name = "RUSTFS_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.daimyo_dev_s3.metadata[0].name
                key  = "AWS_SECRET_ACCESS_KEY"
              }
            }
          }
          env {
            name  = "RUSTFS_ADDRESS"
            value = ":9000"
          }
          env {
            name  = "RUSTFS_VOLUMES"
            value = "/data"
          }
          env {
            name  = "RUSTFS_CONSOLE_ENABLE"
            value = "false"
          }

          port {
            name           = "s3"
            container_port = 9000
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 9000
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }
        }

        volume {
          name = "data"
          empty_dir {
            size_limit = "5Gi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

resource "kubernetes_service_v1" "daimyo_dev_s3" {
  depends_on = [kubernetes_stateful_set_v1.daimyo_dev_s3]

  metadata {
    name      = "daimyo-dev-s3"
    namespace = local.daimyo_dev_ns
    labels    = local.daimyo_dev_labels
  }

  spec {
    selector = { app = "daimyo-dev-s3" }
    port {
      name        = "s3"
      port        = 9000
      target_port = 9000
    }
    type = "ClusterIP"
  }
}
