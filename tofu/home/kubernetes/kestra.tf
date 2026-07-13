# =============================================================================
# Kestra OSS — host aether-k8s automation plane (Inquest prerequisite)
# =============================================================================
# YAML-first orchestrator for alert→ticket→investigate flows and future
# platform glue (replacing n8n/Windmill/cron per docs/exploration).
#
# Auth planes:
#   UI:     HTTPRoute at kestra.home.shdr.ch (gateway; Keycloak forward_auth
#           can be layered on the home gateway later — OSS has no native OIDC)
#   API:    basic auth (Terraform provider + operators)
#   Webhook: path key + basic auth (Grafana contact point)
#
# DB: CNPG Postgres in this namespace. Storage: local PVC for OSS file storage.

locals {
  kestra_ns             = module.namespace["kestra"].name
  kestra_host           = "kestra.home.shdr.ch"
  kestra_chart_version  = "1.0.47"
  kestra_cnpg_cluster   = "kestra-cnpg"
  kestra_db             = "kestra"
  kestra_db_user        = "kestra"
  kestra_db_host        = "${local.kestra_cnpg_cluster}-rw.${local.kestra_ns}.svc.cluster.local"
  kestra_jdbc_url       = "jdbc:postgresql://${local.kestra_db_host}:5432/${local.kestra_db}"
  kestra_basic_user     = var.secrets["kestra.basic_auth_username"]
  kestra_basic_password = var.secrets["kestra.basic_auth_password"]
  kestra_labels         = { app = "kestra" }
}

resource "random_password" "kestra_postgres_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "kestra_cnpg_app" {
  depends_on = [module.namespace["kestra"]]

  metadata {
    name      = "kestra-cnpg-app"
    namespace = local.kestra_ns
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = local.kestra_db_user
    password = random_password.kestra_postgres_password.result
  }
}

resource "kubernetes_secret_v1" "kestra_config" {
  depends_on = [module.namespace["kestra"]]

  metadata {
    name      = "kestra-config"
    namespace = local.kestra_ns
  }

  type = "Opaque"

  data = {
    "application-secrets.yml" = yamlencode({
      datasources = {
        postgres = {
          url             = local.kestra_jdbc_url
          username        = local.kestra_db_user
          password        = random_password.kestra_postgres_password.result
          driverClassName = "org.postgresql.Driver"
        }
      }
      kestra = {
        server = {
          basicAuth = {
            enabled  = true
            username = local.kestra_basic_user
            password = local.kestra_basic_password
          }
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "kestra_inquest" {
  depends_on = [module.namespace["kestra"]]

  metadata {
    name      = "kestra-inquest"
    namespace = local.kestra_ns
  }

  type = "Opaque"

  data = {
    # Non-secret flow vars: ENV_* → {{ envs.<lowercase> }}
    ENV_INQUEST_GITLAB_URL     = "https://gitlab.home.shdr.ch"
    ENV_INQUEST_GITLAB_PROJECT = "so/aether/incidents"
    ENV_HOLMES_URL             = "http://holmes-holmes.holmesgpt.svc"
    ENV_HOLMES_MODEL           = "router/glm-5.2"
    ENV_APPRISE_NOTIFY_URL     = "https://apprise.home.shdr.ch/notify/aether"
    ENV_APPRISE_TAG            = "standard"
    # Secrets: SECRET_* must be base64 → {{ secret('NAME') }} (no SECRET_ prefix)
    SECRET_INQUEST_GITLAB_TOKEN = base64encode(var.secrets["inquest.gitlab_token"])
    SECRET_INQUEST_WEBHOOK_KEY  = base64encode(var.secrets["inquest.webhook_key"])
  }
}

resource "kubernetes_secret_v1" "kestra_estate_scan" {
  depends_on = [module.namespace["kestra"]]

  metadata {
    name      = "kestra-estate-scan"
    namespace = local.kestra_ns
  }

  type = "Opaque"

  data = {
    ENV_ESTATE_SCANNER_HOST = "10.0.2.13"
    ENV_ESTATE_SCANNER_USER = "kestra-estate-scanner"
    # SECRET_* → {{ secret('NAME') }} (no SECRET_ prefix); base64 required by Kestra.
    SECRET_ESTATE_SCANNER_SSH_KEY = base64encode(var.secrets["estate_scan.kestra_ssh_private_key"])
  }
}

resource "kubectl_manifest" "kestra_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.kestra_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.kestra_cnpg_cluster
      namespace = local.kestra_ns
      labels    = local.kestra_labels
    }
    spec = {
      instances = 1
      imageName = "ghcr.io/cloudnative-pg/postgresql:17.9"
      affinity = {
        nodeSelector = { "kubernetes.io/arch" = "amd64" }
      }
      storage = {
        size         = "20Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["kestra"]
      bootstrap = {
        initdb = {
          database = local.kestra_db
          owner    = local.kestra_db_user
          secret = {
            name = kubernetes_secret_v1.kestra_cnpg_app.metadata[0].name
          }
        }
      }
    }
  })
}

resource "kubernetes_persistent_volume_claim_v1" "kestra_storage" {
  depends_on = [module.namespace["kestra"], kubernetes_storage_class_v1.ceph_rbd]

  metadata {
    name      = "kestra-storage"
    namespace = local.kestra_ns
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

resource "helm_release" "kestra" {
  depends_on = [
    kubectl_manifest.kestra_cnpg_cluster,
    kubernetes_secret_v1.kestra_config,
    kubernetes_secret_v1.kestra_inquest,
    kubernetes_secret_v1.kestra_estate_scan,
    kubernetes_persistent_volume_claim_v1.kestra_storage,
  ]

  name             = "kestra"
  repository       = "https://helm.kestra.io/"
  chart            = "kestra"
  version          = local.kestra_chart_version
  namespace        = local.kestra_ns
  create_namespace = false
  wait             = true
  timeout          = 900

  values = [yamlencode({
    fullnameOverride = "kestra"

    common = {
      nodeSelector = { "kubernetes.io/arch" = "amd64" }

      # Recreate (not RollingUpdate): the standalone pod mounts the RWO ceph-rbd
      # kestra-storage PVC. A surge pod can never mount the volume the old pod
      # holds, so a rolling update deadlocks until the old pod is force-killed —
      # which orphans in-flight taskruns (executor+worker die together in
      # standalone) and leaks the alert-intake concurrency slot. Recreate stops
      # the old pod (releasing the PVC) before starting the new one.
      strategy = { type = "Recreate" }
      podAnnotations = {
        "aether.shdr.ch/kestra-inquest-sha"     = sha256(jsonencode(nonsensitive(kubernetes_secret_v1.kestra_inquest.data)))
        "aether.shdr.ch/kestra-estate-scan-sha" = sha256(jsonencode(nonsensitive(kubernetes_secret_v1.kestra_estate_scan.data)))
      }
      extraEnvFrom = [
        { secretRef = { name = kubernetes_secret_v1.kestra_inquest.metadata[0].name } },
        { secretRef = { name = kubernetes_secret_v1.kestra_estate_scan.metadata[0].name } },
      ]
      extraVolumeMounts = [{
        name      = "kestra-storage"
        mountPath = "/app/storage"
      }]
      extraVolumes = [{
        name = "kestra-storage"
        persistentVolumeClaim = {
          claimName = kubernetes_persistent_volume_claim_v1.kestra_storage.metadata[0].name
        }
      }]
    }

    configurations = {
      application = {
        kestra = {
          queue      = { type = "postgres" }
          repository = { type = "postgres" }
          storage = {
            type  = "local"
            local = { basePath = "/app/storage" }
          }

          # Self-heal orphaned taskruns if the pod dies mid-execution anyway.
          # In standalone the executor+worker share a process; on an abnormal
          # kill, worker tasks are resubmitted once the dead service's heartbeat
          # goes stale (liveness), and the concurrency slot is reconciled on the
          # execution's terminal event instead of leaking.
          server = {
            liveness = {
              enabled = true
              timeout = "45s"
            }
            workerTaskRestartStrategy = "AFTER_TERMINATION_GRACE_PERIOD"
          }
        }
      }
      secrets = [{
        name = kubernetes_secret_v1.kestra_config.metadata[0].name
        key  = "application-secrets.yml"
      }]
    }

    deployments = {
      standalone = {
        enabled = true
        # No dind for Inquest MVP (HTTP + Go glue only).
        dind = { enabled = false }
      }
    }
  })]
}

# =============================================================================
# Kestra — estate-scanner dispatch
# =============================================================================
# Secret kestra-estate-scan mounts ENV_ESTATE_SCANNER_* + SECRET_ESTATE_SCANNER_SSH_KEY.
# Flow YAML: kestra/flows/estate-scan-home.yaml
# Flow IaC: tofu/home/kestra-flows/ (separate S3 state; task tofu:kestra-flows:apply)
#
# Path: SERVICES (Talos) → TRUSTED rule 26 → estate-scanner:22 only.
# Source group TALOS-NODES (node SNAT). Not Proxmox/MGMT. Rule 25 is SeaweedFS.
# Apply path: ansible/playbooks/home_router/allow_estate_scanner_dispatch.yml
# (also declared in configure_router.yml for full reconciles).
# =============================================================================

resource "kubernetes_manifest" "kestra_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.kestra]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "kestra"
      namespace = local.kestra_ns
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.kestra_host]
      rules = [{
        backendRefs = [{
          name = "kestra"
          port = 8080
        }]
      }]
    }
  }
}
