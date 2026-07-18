# =============================================================================
# Assay — personal-finance ingestion and review API
# =============================================================================
# Application behavior, Temporal workflows, and chart templates live in
# ../assay. Aether owns only the hosting coordinates and platform resources.

locals {
  assay_namespace            = module.namespace["assay"].name
  assay_host                 = "assay.home.shdr.ch"
  assay_chart_version        = "0.2.7"
  assay_image_tag            = "v0.2.7"
  assay_registry_host        = "registry.gitlab.home.shdr.ch"
  assay_registry_repository  = "${local.assay_registry_host}/so/assay"
  assay_cnpg                 = "assay-cnpg"
  assay_database             = "assay"
  assay_database_user        = "assay"
  assay_database_service     = "${local.assay_cnpg}-rw.${local.assay_namespace}.svc.cluster.local"
  assay_artifact_endpoint    = "https://s3.seaweed.home.shdr.ch"
  assay_artifact_bucket      = "assay-artifacts"
  assay_artifact_prefix      = "assay/td"
  assay_browser_profile_name = "assay-browser-profile"
  assay_labels               = { app = "assay" }
}

resource "random_password" "assay_database_password" {
  length  = 32
  special = false
}

resource "random_password" "assay_api_token" {
  length  = 48
  special = false
}

resource "random_password" "assay_cockpit_session_secret" {
  length  = 48
  special = false
}

resource "random_password" "assay_artifact_s3_access_key" {
  length  = 20
  special = false
}

resource "random_password" "assay_artifact_s3_secret_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "assay_cnpg_app" {
  depends_on = [module.namespace["assay"]]

  metadata {
    name      = "assay-cnpg-app"
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = local.assay_database_user
    password = random_password.assay_database_password.result
  }
}

resource "kubernetes_secret_v1" "assay_api_env" {
  depends_on = [module.namespace["assay"]]

  metadata {
    name      = "assay-api-env"
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  type = "Opaque"
  data = {
    DATABASE_URL = "postgresql://${local.assay_database_user}:${random_password.assay_database_password.result}@${local.assay_database_service}:5432/${local.assay_database}?sslmode=disable"
  }
}

resource "kubernetes_secret_v1" "assay_api_auth" {
  depends_on = [module.namespace["assay"]]

  metadata {
    name      = "assay-api-auth"
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  type = "Opaque"
  data = {
    ASSAY_API_TOKEN = random_password.assay_api_token.result
  }
}
resource "kubernetes_secret_v1" "assay_llm" {
  depends_on = [module.namespace["assay"]]

  metadata {
    name      = "assay-llm"
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  type = "Opaque"
  data = {
    EXPLORE_LLM_API_KEY = var.secrets["litellm.virtual_keys.assay"]
  }
}


resource "kubernetes_secret_v1" "assay_cockpit_auth" {
  depends_on = [module.namespace["assay"]]

  metadata {
    name      = "assay-cockpit-auth"
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  type = "Opaque"
  data = {
    OIDC_ISSUER         = "https://auth.shdr.ch/realms/aether"
    OIDC_CLIENT_ID      = "assay-cockpit"
    OIDC_CLIENT_SECRET  = var.assay_oauth_client_secret
    OIDC_REDIRECT_URI   = "https://${local.assay_host}/auth/callback"
    OIDC_ALLOWED_EMAILS = var.assay_allowed_email
    SESSION_SECRET      = random_password.assay_cockpit_session_secret.result
  }
}

resource "kubectl_manifest" "assay_td_external_secret" {
  depends_on = [
    kubectl_manifest.namespace_secret_store["assay"],
  ]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "assay-td-env"
      namespace = local.assay_namespace
      labels    = local.assay_labels
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        kind = "SecretStore"
        name = "openbao"
      }
      target = {
        name           = "assay-td-env"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "TD_USERNAME"
          remoteRef = {
            key      = "${local.eso_secret_path_prefix}/${local.assay_namespace}/td"
            property = "TD_USERNAME"
          }
        },
        {
          secretKey = "TD_PASSWORD"
          remoteRef = {
            key      = "${local.eso_secret_path_prefix}/${local.assay_namespace}/td"
            property = "TD_PASSWORD"
          }
        },
      ]
    }
  })
}

# Grafana owns the tenant service-account lifecycle and writes its token to
# OpenBao. Assay only receives the resulting scoped token through ESO; the
# Helm chart owns the dashboard and unified alert rule definitions themselves.
resource "kubectl_manifest" "assay_grafana_external_secret" {
  depends_on = [
    kubectl_manifest.namespace_secret_store["assay"],
  ]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "assay-grafana"
      namespace = local.assay_namespace
      labels    = local.assay_labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "SecretStore"
        name = "openbao"
      }
      target = {
        name           = "assay-grafana"
        creationPolicy = "Owner"
      }
      data = [{
        secretKey = "GRAFANA_TOKEN"
        remoteRef = {
          key      = "${local.assay_namespace}/grafana"
          property = "api_token"
        }
      }]
    }
  })
}

resource "kubernetes_secret_v1" "assay_artifact_store" {
  depends_on = [module.namespace["assay"]]

  metadata {
    name      = "assay-object-store-env"
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  type = "Opaque"
  data = {
    AWS_ACCESS_KEY_ID     = random_password.assay_artifact_s3_access_key.result
    AWS_SECRET_ACCESS_KEY = random_password.assay_artifact_s3_secret_key.result
  }
}

resource "terraform_data" "assay_artifact_bucket" {
  triggers_replace = [local.assay_artifact_bucket]

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
      S3_ENDPOINT               = local.assay_artifact_endpoint
      S3_BUCKET                 = local.assay_artifact_bucket
    }
  }
}

resource "kubernetes_secret_v1" "assay_gitlab_registry" {
  depends_on = [module.namespace["assay"]]

  metadata {
    name      = "assay-gitlab-registry"
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.assay_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

resource "kubernetes_persistent_volume_claim_v1" "assay_browser_profile" {
  depends_on = [
    module.namespace["assay"],
    kubernetes_storage_class_v1.ceph_rbd,
  ]

  metadata {
    name      = local.assay_browser_profile_name
    namespace = local.assay_namespace
    labels    = local.assay_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = local.cnpg_storage_class
    resources {
      requests = { storage = "2Gi" }
    }
  }
}

resource "kubectl_manifest" "assay_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubernetes_secret_v1.assay_cnpg_app,
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.assay_cnpg
      namespace = local.assay_namespace
      labels    = merge(local.assay_labels, { "aether.sh/arm-ok" = "true" })
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
      plugins = local.cnpg_plugin_specs["assay"]
      bootstrap = {
        initdb = {
          database = local.assay_database
          owner    = local.assay_database_user
          secret   = { name = kubernetes_secret_v1.assay_cnpg_app.metadata[0].name }
          postInitApplicationSQL = [
            "CREATE EXTENSION IF NOT EXISTS vector",
          ]
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "helm_release" "assay" {
  depends_on = [
    helm_release.reloader,
    helm_release.grafana_operator,
    kubectl_manifest.assay_cnpg_cluster,
    kubectl_manifest.assay_td_external_secret,
    kubectl_manifest.assay_grafana_external_secret,
    kubernetes_manifest.main_gateway,
    kubernetes_persistent_volume_claim_v1.assay_browser_profile,
    kubernetes_secret_v1.assay_api_auth,
    kubernetes_secret_v1.assay_api_env,
    kubernetes_secret_v1.assay_llm,
    kubernetes_secret_v1.assay_cockpit_auth,
    kubernetes_secret_v1.assay_artifact_store,
    kubernetes_secret_v1.assay_gitlab_registry,
    terraform_data.assay_artifact_bucket,
  ]

  name                = "assay"
  repository          = "oci://${local.assay_registry_repository}"
  chart               = "assay"
  namespace           = local.assay_namespace
  version             = local.assay_chart_version
  repository_username = var.secrets["gitlab.root_email"]
  repository_password = var.secrets["gitlab.root_password"]
  wait                = true
  wait_for_jobs       = true
  atomic              = true
  timeout             = 900

  values = [yamlencode({
    platform = {
      imagePullSecrets = [{ name = kubernetes_secret_v1.assay_gitlab_registry.metadata[0].name }]
      database = {
        secretRef = {
          name           = kubernetes_secret_v1.assay_api_env.metadata[0].name
          databaseUrlKey = "DATABASE_URL"
        }
      }
      apiAuth = {
        secretRef = {
          name     = kubernetes_secret_v1.assay_api_auth.metadata[0].name
          tokenKey = "ASSAY_API_TOKEN"
        }
      }
      cockpitAuth = {
        secretRef = {
          name = kubernetes_secret_v1.assay_cockpit_auth.metadata[0].name
        }
      }
      tdCredentials = {
        secretRef = {
          name        = "assay-td-env"
          usernameKey = "TD_USERNAME"
          passwordKey = "TD_PASSWORD"
        }
      }
      objectStore = {
        endpoint       = local.assay_artifact_endpoint
        bucket         = local.assay_artifact_bucket
        region         = "us-east-1"
        forcePathStyle = true
        secretRef = {
          name               = kubernetes_secret_v1.assay_artifact_store.metadata[0].name
          accessKeyIdKey     = "AWS_ACCESS_KEY_ID"
          secretAccessKeyKey = "AWS_SECRET_ACCESS_KEY"
          sessionTokenKey    = "AWS_SESSION_TOKEN"
        }
      }
      temporal = {
        address   = "temporal-server.temporal.svc.cluster.local:7233"
        namespace = "default"
      }
      mnemo = {
        url = "https://mnemo.home.shdr.ch"
      }
      explore = {
        enabled  = true
        baseUrl  = "http://${kubernetes_service_v1.litellm.metadata[0].name}.${local.litellm_ns}.svc.cluster.local:${local.litellm_port}/v1"
        model    = "aether/qwen3.6-27b"
        maxSteps = 8
        secretRef = {
          name      = kubernetes_secret_v1.assay_llm.metadata[0].name
          apiKeyKey = "EXPLORE_LLM_API_KEY"
        }
      }
      grafana = {
        enabled       = true
        url           = "https://grafana.home.shdr.ch"
        prometheusUid = "ffs597mxke39ca"
        secretRef = {
          name     = "assay-grafana"
          tokenKey = "GRAFANA_TOKEN"
        }
      }
      telemetry = {
        otlpEndpoint = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318"
      }
      gateway = {
        enabled = true
        host    = local.assay_host
        parentRef = {
          name      = "main-gateway"
          namespace = "default"
        }
      }
      browserProfile = {
        existingClaim    = kubernetes_persistent_volume_claim_v1.assay_browser_profile.metadata[0].name
        storageClassName = local.cnpg_storage_class
        retain           = true
        accessModes      = ["ReadWriteOnce"]
        size             = "2Gi"
      }
    }
    api = {
      image = {
        repository = "${local.assay_registry_repository}/api"
        tag        = local.assay_image_tag
        pullPolicy = "IfNotPresent"
      }
    }
    cockpit = {
      enabled = true
      image = {
        repository = "${local.assay_registry_repository}/cockpit"
        tag        = local.assay_image_tag
        pullPolicy = "IfNotPresent"
      }
    }
    worker = {
      headless = false
      image = {
        repository = "${local.assay_registry_repository}/worker"
        tag        = local.assay_image_tag
        pullPolicy = "IfNotPresent"
      }
      nodeSelector = { "kubernetes.io/arch" = "amd64" }
    }
    assay = {
      artifactStore = {
        type                = "s3"
        filesystemDirectory = "/data/td-exports"
        prefix              = local.assay_artifact_prefix
      }
      insights = {
        schedule = {
          enabled  = true
          id       = "assay-insights-daily"
          cron     = "0 6 * * *"
          timezone = "America/Toronto"
        }
      }
      tdIngestion = {
        taskQueue = "assay-td-ingest"
        accountLabelsJson = jsonencode({
          "chequing-primary" = "TD UNLIMITED CHEQUING ACCOUNT"
          "savings-primary"  = { label = "TD EVERY DAY SAVINGS ACCOUNT", accountNumber = "6118573" }
          "savings-rent"     = { label = "TD EVERY DAY SAVINGS ACCOUNT", accountNumber = "6163366" }
          "credit-primary"   = { label = "TD CASH BACK VISA INFINITE* CARD", accountNumberLast4 = "3325", product = "credit" }
        })
        mnemo = {
          source         = "matrix"
          query          = "TD security code"
          messagePattern = "\\bTD\\b[\\s\\S]*\\bsecurity code\\b"
        }
        schedule = {
          enabled      = true
          id           = "assay-td-hourly"
          cron         = "0 * * * *"
          timezone     = "America/Toronto"
          lookbackDays = 7
          accounts = [
            {
              accountId  = "6a419c94-df2a-4ebb-a65c-e77ce7758ecc"
              accountRef = "chequing-primary"
              sourceId   = "8abb6760-f606-4fca-82db-6f163b01d2b4"
            },
            {
              accountId  = "1e0d901f-157a-4da8-950c-89432955eaf7"
              accountRef = "savings-primary"
              sourceId   = "8abb6760-f606-4fca-82db-6f163b01d2b4"
            },
            {
              accountId  = "2741a87d-d5f1-4a92-a746-adbc15aac94d"
              accountRef = "savings-rent"
              sourceId   = "8abb6760-f606-4fca-82db-6f163b01d2b4"
            },
            {
              accountId  = "3f46bf7d-41f7-4c1e-9de8-67c6c0194e25"
              accountRef = "credit-primary"
              sourceId   = "8abb6760-f606-4fca-82db-6f163b01d2b4"
            },
          ]
        }
      }
    }
  })]
}

resource "kubernetes_manifest" "assay_api_ingress" {
  depends_on = [
    helm_release.assay,
    kubernetes_manifest.cilium_cluster_baseline_network,
  ]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "assay-api-ingress"
      namespace = local.assay_namespace
    }
    spec = {
      endpointSelector = {
        matchLabels = { "app.kubernetes.io/component" = "api" }
      }
      ingress = [
        {
          fromEntities = ["ingress"]
          toPorts      = [{ ports = [{ port = "3000", protocol = "TCP" }] }]
        },
        {
          fromEndpoints = [{
            matchLabels = { "io.kubernetes.pod.namespace" = local.assay_namespace }
          }]
          toPorts = [{ ports = [{ port = "3000", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
