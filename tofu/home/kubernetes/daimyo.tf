# =============================================================================
# Daimyo — self-hosted agent control plane (sibling repo ../daimyo)
# =============================================================================
# Daimyo ships the container images (registry.gitlab.home.shdr.ch/so/
# daimyo/*, pinned by digest from CI) plus its Helm chart
# (../daimyo/deploy/helm/daimyo); aether owns every cluster object. The chart
# carries its NATS subchart, CNPG Cluster and RBAC; this file owns the
# namespaces (via namespace_contracts.tf), the registry pull secret, the
# credential Secrets, the Helm release, the Org/Project/Agent bootstrap CRs,
# the task-namespace CiliumNetworkPolicies, and the HTTPRoute.
#
# Requires the daimyo checkout as a sibling of aether
# (../daimyo/deploy/helm/daimyo/Chart.yaml) — copy the hermes.tf
# precondition pattern: fail with an actionable message, not file() noise.
#
# Stages (targeted plans, smallest blast radius first):
#   1. namespaces/contracts (namespace_contracts.tf stanzas, this file: none)
#   2. OpenBao/Keycloak (openbao_daimyo.tf, keycloak.tf, keycloak_seven30.tf)
#   3. backing stores (S3 buckets/identities below, CNPG via the chart)
#   4. helm_release.daimyo + HTTPRoute (this file)
#   5. Caddy: `*.home.shdr.ch` wildcard already routes to the Gateway VIP;
#      no Caddy change needed.

locals {
  # path.module is tofu/home/kubernetes: four levels up reaches ~/projects.
  daimyo_chart_path = "${path.module}/../../../../daimyo/deploy/helm/daimyo"
  # NOTE: the chart's helpers treat a `sha256:`-prefixed tag as a digest
  # (`repo@sha256:…`), so pass the digest as the tag (M1E2EAether's fix).
  # d7e6ec1 (pipeline 6422, so/daimyo): agent execution "run" -> "task",
  # "human task" -> "approval" (migration 0008, `<org>-tasks` namespaces).
  daimyo_server_tag  = "sha256:341c857504c317f381521380ae6843937718e51a266d28e6cce4315b8803006d"
  daimyo_sidecar_tag = "sha256:7d2a04514c87c3de4884183f80b24e1d0af812a069d57248b02f8dc1fda8aba0"
  # These are the newest main images at deploy time; bump intentionally.
  daimyo_server_image  = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-server@sha256:341c857504c317f381521380ae6843937718e51a266d28e6cce4315b8803006d"
  daimyo_sidecar_image = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-sidecar@sha256:7d2a04514c87c3de4884183f80b24e1d0af812a069d57248b02f8dc1fda8aba0"
  # d7e6ec1 echo (pipeline 6422).
  daimyo_echo_image = "registry.gitlab.home.shdr.ch/so/daimyo/echo-agent@sha256:fcc3058613f355cefa107d20b1df31f1198fe266d121ebc342190cb47b4a4ca3"
  daimyo_ns            = module.namespace["daimyo-system"].name
  daimyo_host          = "daimyo.home.shdr.ch"
  daimyo_registry_host = "registry.gitlab.home.shdr.ch"
  daimyo_labels        = { app = "daimyo" }
  # Model alias the bootstrap echo agent's grant names. Must exist in
  # aether's LiteLLM config (litellm_config.yaml.tftpl): a cheap real alias
  # so key minting succeeds even though echo never calls the model.
  daimyo_echo_model  = "moira/flash"
  daimyo_orgs        = toset(["personal", "seven30"])
  daimyo_s3_endpoint = "https://s3.seaweed.home.shdr.ch"
  daimyo_s3_region   = "us-east-1"
  # Static in-cluster service names (not resource references): referencing
  # live resources pulls their dependency chains into every targeted plan.
  daimyo_litellm_upstream = "http://litellm.litellm.svc.cluster.local:4000"
  daimyo_svc_name         = "daimyo-api"
}

# --- Sibling-checkout precondition ------------------------------------------------
# Mirrors hermes.tf: the chart is vendored from the sibling repo at apply
# time, so a missing checkout must fail with an actionable message.

resource "terraform_data" "daimyo_chart_present" {
  lifecycle {
    precondition {
      condition     = fileexists("${local.daimyo_chart_path}/Chart.yaml")
      error_message = "Daimyo chart not found at ${local.daimyo_chart_path}/Chart.yaml — clone the daimyo repo as a sibling of aether (next to ~/projects/aether) before running tofu apply."
    }
  }
}

# --- Registry pull secret (server/migrate pods + task pods) -----------------------

resource "kubernetes_secret_v1" "daimyo_registry" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "daimyo-gitlab-registry"
    namespace = local.daimyo_ns
    labels    = local.daimyo_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.daimyo_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

# Each tasks namespace needs its own copy: task pods reference it by name and
# cross-namespace secret references do not exist.
resource "kubernetes_secret_v1" "daimyo_tasks_registry" {
  for_each   = local.daimyo_orgs
  depends_on = [module.namespace["personal-tasks"], module.namespace["seven30-tasks"]]

  metadata {
    name      = "daimyo-gitlab-registry"
    namespace = "${each.key}-tasks"
    labels    = local.daimyo_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.daimyo_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

# --- Credential Secrets (chart `secrets.*` + `secretFiles.*`) ---------------------
# The chart never creates credential Secrets; it mounts these read-only into
# the server/migrate pods (see _dbinit.tpl). CNPG `managed.roles` generates
# the api/engine passwords into the Secrets below at Cluster bootstrap.

resource "random_password" "daimyo_postgres_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "daimyo_postgres" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "daimyo-postgres"
    namespace = local.daimyo_ns
    labels    = local.daimyo_labels
  }

  type = "Opaque"
  data = {
    password = random_password.daimyo_postgres_password.result
  }
}

resource "kubernetes_secret_v1" "daimyo_postgres_api" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "daimyo-postgres-api"
    namespace = local.daimyo_ns
    labels    = local.daimyo_labels
  }

  type = "Opaque"
  data = {
    # Placeholder: CNPG managed.roles overwrites with the generated password.
    password = random_password.daimyo_postgres_password.result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret_v1" "daimyo_postgres_engine" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "daimyo-postgres-engine"
    namespace = local.daimyo_ns
    labels    = local.daimyo_labels
  }

  type = "Opaque"
  data = {
    # Placeholder: CNPG managed.roles overwrites with the generated password.
    password = random_password.daimyo_postgres_password.result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret_v1" "daimyo_litellm" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "daimyo-litellm"
    namespace = local.daimyo_ns
    labels    = local.daimyo_labels
  }

  type = "Opaque"
  data = {
    admin-key = var.secrets["litellm.master_key"]
  }
}

# OpenBao token for the Transit signer + KV secrets reader. The token is a
# periodic token minted from the deploy credential with the daimyo-server
# policy (openbao_daimyo.tf); it is stored here, never in values. Rotation:
# re-run the mint command below and `tofu apply` (the server reads the token
# file on every request, so no restart is needed for the signer path).
resource "kubernetes_secret_v1" "daimyo_openbao" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "daimyo-openbao"
    namespace = local.daimyo_ns
    labels    = local.daimyo_labels
  }

  type = "Opaque"
  data = {
    # Placeholder replaced by the operator-minted periodic token (stage 2).
    token = "placeholder-rotate-me"
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# S3 identity for archives/artifacts/audit + CNPG barman backup. Scoped like
# the siren identity in db_backups.tf (buckets + /*), pushed with
# `task seaweedfs:s3-identities:deploy` after apply.
resource "random_password" "daimyo_s3_access_key" {
  length  = 20
  special = false
}

resource "random_password" "daimyo_s3_secret_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "daimyo_s3" {
  depends_on = [module.namespace["daimyo-system"]]

  metadata {
    name      = "daimyo-s3"
    namespace = local.daimyo_ns
    labels    = local.daimyo_labels
  }

  type = "Opaque"
  data = {
    AWS_ACCESS_KEY_ID     = random_password.daimyo_s3_access_key.result
    AWS_SECRET_ACCESS_KEY = random_password.daimyo_s3_secret_key.result
    AWS_DEFAULT_REGION    = local.daimyo_s3_region
  }
}

resource "terraform_data" "daimyo_buckets" {
  depends_on = [random_password.daimyo_s3_access_key, random_password.daimyo_s3_secret_key]

  triggers_replace = ["daimyo-personal,daimyo-seven30,daimyo-backups"]

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
      AWS_DEFAULT_REGION        = "us-east-1"
      AWS_EC2_METADATA_DISABLED = "true"
      S3_ENDPOINT               = local.daimyo_s3_endpoint
      S3_BUCKETS                = "daimyo-personal daimyo-seven30 daimyo-backups"
    }
  }
}

# --- Helm release (chart from the sibling checkout) --------------------------------
# helm_release with a local chart path (no repository): the chart directory
# itself is the source. CRDs in the chart's crds/ install once at release
# creation. Values mirror the e2e gate's proven shape (values-e2e.yaml) with
# production stores: CNPG, Transit signer, OpenBao KV, real LiteLLM.

resource "helm_release" "daimyo" {
  depends_on = [
    terraform_data.daimyo_chart_present,
    module.namespace["daimyo-system"],
    module.namespace["org-personal"],
    module.namespace["org-seven30"],
    module.namespace["personal-tasks"],
    module.namespace["seven30-tasks"],
    kubernetes_secret_v1.daimyo_registry,
    kubernetes_secret_v1.daimyo_tasks_registry,
    kubernetes_secret_v1.daimyo_postgres,
    kubernetes_secret_v1.daimyo_postgres_api,
    kubernetes_secret_v1.daimyo_postgres_engine,
    kubernetes_secret_v1.daimyo_litellm,
    kubernetes_secret_v1.daimyo_openbao,
    kubernetes_secret_v1.daimyo_s3,
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
  ]

  name      = "daimyo"
  chart     = local.daimyo_chart_path
  namespace = local.daimyo_ns
  wait      = true
  atomic    = true
  timeout   = 900

  values = [yamlencode({
    fullnameOverride = "daimyo"
    replicaCount     = 2
    imagePullSecrets = [{ name = kubernetes_secret_v1.daimyo_registry.metadata[0].name }]
    image = {
      repository = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-server"
      tag        = local.daimyo_server_tag
      pullPolicy = "IfNotPresent"
    }
    sidecarImage = {
      repository = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-sidecar"
      tag        = local.daimyo_sidecar_tag
    }
    secrets = {
      postgres       = kubernetes_secret_v1.daimyo_postgres.metadata[0].name
      postgresApi    = kubernetes_secret_v1.daimyo_postgres_api.metadata[0].name
      postgresEngine = kubernetes_secret_v1.daimyo_postgres_engine.metadata[0].name
    }
    secretFiles = {
      litellmAdminKey = {
        secretName = kubernetes_secret_v1.daimyo_litellm.metadata[0].name
        key        = "admin-key"
        mountPath  = "/etc/daimyo/secrets/litellm-admin-key"
      }
      openbaoToken = {
        secretName = kubernetes_secret_v1.daimyo_openbao.metadata[0].name
        key        = "token"
        mountPath  = "/etc/daimyo/secrets/openbao-token"
      }
    }
    config = {
      publicBaseUrl = "https://daimyo.home.shdr.ch"
      listen        = "0.0.0.0:8080"
      apiUpstream   = "http://daimyo-api.daimyo-system.svc:80"
      database = {
        ownerUrl  = "postgres://daimyo:__DB_PASSWORD_owner__@daimyo-pg-rw:5432/daimyo"
        apiUrl    = "postgres://daimyo_api:__DB_PASSWORD_api__@daimyo-pg-rw:5432/daimyo"
        engineUrl = "postgres://daimyo_engine:__DB_PASSWORD_engine__@daimyo-pg-rw:5432/daimyo"
      }
      nats = {
        default = { url = "nats://daimyo-nats:4222" }
        orgs    = {}
      }
      signer = {
        kind      = "transit"
        pemDir    = null
        orgs      = []
        address   = "https://bao.home.shdr.ch"
        tokenFile = "/etc/daimyo/secrets/openbao-token"
      }
      litellm = {
        upstream     = local.daimyo_litellm_upstream
        adminKeyFile = "/etc/daimyo/secrets/litellm-admin-key"
      }
      secrets = {
        kind      = "openbao"
        address   = "https://bao.home.shdr.ch"
        mount     = "kv"
        tokenFile = "/etc/daimyo/secrets/openbao-token"
        values    = {}
      }
      git = {
        defaultBaseUrl = "https://gitlab.home.shdr.ch"
      }
      metricsListen = "0.0.0.0:9090"
      storage = {
        endpoint        = local.daimyo_s3_endpoint
        accessKeyId     = random_password.daimyo_s3_access_key.result
        secretAccessKey = random_password.daimyo_s3_secret_key.result
        region          = local.daimyo_s3_region
      }
      otel = { endpoint = null }
      launcher = {
        kind             = "kata"
        runtimeClass     = "kata"
        sidecarImage     = ""
        imagePullSecrets = [kubernetes_secret_v1.daimyo_tasks_registry["personal"].metadata[0].name]
      }
    }
    orgs = [
      { name = "personal" },
      { name = "seven30" },
    ]
    # The chart's migrate hook can't run here: it fires before the CNPG
    # Cluster's Service exists on install, and it disables the SA token that
    # `--roles none` still needs for the kata launcher. See the note at the
    # end of this file for how migrations run.
    migrate = { enabled = false }
    serviceAccount = {
      create = true
      name   = "daimyo-server"
    }
    rbac    = { create = true }
    service = { type = "ClusterIP", port = 80, targetPort = 8080, metricsPort = 9090 }
    pdb     = { create = true, minAvailable = 1 }
    # Ingress to task pods comes from the CiliumNetworkPolicies below (the
    # chart's NetworkPolicy selects by the wrong label); keep it off.
    networkPolicy = { create = false }
    cnpg = {
      enabled     = true
      clusterName = "daimyo-pg"
      instances   = 2
      imageName   = "ghcr.io/cloudnative-pg/postgresql:17"
      storageSize = "20Gi"
      # Kyverno cnpg-require-ceph-rbd-storage Enforces this exact class.
      storageClass = "ceph-rbd"
      backup = {
        enabled           = true
        credentialsSecret = kubernetes_secret_v1.daimyo_s3.metadata[0].name
        endpointURL       = local.daimyo_s3_endpoint
        destinationPath   = "s3://daimyo-backups/"
      }
      database  = "daimyo"
      owner     = "daimyo"
      extraSpec = {}
    }
    devPostgres = { enabled = false }
    nats = {
      enabled = true
      config = {
        cluster   = { enabled = true, replicas = 3 }
        jetstream = { enabled = true, fileStore = { pvc = { enabled = true, size = "10Gi" } } }
      }
      natsBox = { enabled = false }
    }
    resources = {
      requests = { cpu = "500m", memory = "512Mi" }
      limits   = { cpu = "2", memory = "2Gi" }
    }
  })]
}

# (The OpenBao Kubernetes-auth role lives in openbao_daimyo.tf next to the
# policy: vault resources must share one module scope. The server
# ServiceAccount itself comes from the chart's rbac.)

resource "kubernetes_manifest" "daimyo_tasks_egress" {
  for_each   = local.daimyo_orgs
  depends_on = [helm_release.cilium, helm_release.daimyo]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "daimyo-tasks-egress"
      namespace = "${each.key}-tasks"
      labels    = local.daimyo_labels
    }
    spec = {
      endpointSelector = {}
      enableDefaultDeny = {
        egress  = true
        ingress = false
      }
      ingress = [
        {
          # The engine reaches agent pods by pod IP on 8080 (chart P5).
          fromEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"      = "daimyo"
              "app.kubernetes.io/component" = "server"
              "io.kubernetes.pod.namespace" = local.daimyo_ns
            }
          }]
          toPorts = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
        },
      ]
      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "k8s-app"                     = "kube-dns"
              "io.kubernetes.pod.namespace" = "kube-system"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
            rules = { dns = [{ matchPattern = "*" }] }
          }]
        },
        {
          # The Daimyo API the sidecar's API grant points at (apiUpstream).
          toEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"      = "daimyo"
              "app.kubernetes.io/component" = "server"
              "io.kubernetes.pod.namespace" = local.daimyo_ns
            }
          }]
          toPorts = [{ ports = [
            { port = "80", protocol = "TCP" },
            { port = "8080", protocol = "TCP" },
          ] }]
        },
        {
          # LiteLLM model gateway (spec §18.1; cluster DNS like hermes.tf).
          toEndpoints = [{
            matchLabels = {
              "app"                         = "litellm"
              "io.kubernetes.pod.namespace" = "litellm"
            }
          }]
          toPorts = [{ ports = [{ port = "4000", protocol = "TCP" }] }]
        },
        {
          # GitLab HTTPS (git grants + registry pulls), npm/pypi (spec §18.1),
          # and the GitLab container registry: FQDN egress, no broad CIDR.
          toFQDNs = [
            { matchName = "gitlab.home.shdr.ch" },
            { matchName = "registry.gitlab.home.shdr.ch" },
            { matchName = "registry.npmjs.org" },
            { matchName = "registry.yarnpkg.com" },
            { matchName = "pypi.org" },
            { matchName = "files.pythonhosted.org" },
          ]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}

# --- HTTPRoute: daimyo.home.shdr.ch ------------------------------------------------
# LAN Caddy already routes `*.home.shdr.ch` to the Gateway VIP (Caddyfile.j2
# wildcard); in-cluster routing is this HTTPRoute on main-gateway. Follows
# the claude.tf route shape (sectionName http + X-Forwarded-Proto).

resource "kubernetes_manifest" "daimyo_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.daimyo]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "daimyo"
      namespace = local.daimyo_ns
      labels    = local.daimyo_labels
    }
    spec = {
      parentRefs = [{
        name        = "main-gateway"
        namespace   = "default"
        sectionName = "http"
      }]
      hostnames = [local.daimyo_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{
          name = local.daimyo_svc_name
          port = 80
        }]
      }]
    }
  }
}

# --- Bootstrap Org/Project/Agent CRs (spec §6.1) ------------------------------------
# In tofu for now (the assignment): each org's own repos will own these
# through the GitLab Agent later. personal/project `personal` carries the
# `echo` agent (echo.say, 1 USD model grant on the cheap real alias above).

resource "kubectl_manifest" "daimyo_org" {
  for_each   = local.daimyo_orgs
  depends_on = [helm_release.daimyo]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Org"
    metadata = {
      name   = each.key
      labels = local.daimyo_labels
    }
    spec = merge(
      {
        issuers = each.key == "personal" ? [
          {
            issuer    = "https://auth.shdr.ch/realms/aether"
            audiences = ["daimyo"]
            principal = { claim = "preferred_username", prefix = "user:" }
            groups    = { claim = "groups" }
          },
        ] : []
        namespaces = { config = "org-${each.key}", tasks = "${each.key}-tasks" }
        quotas     = { concurrentTasks = 10 }
        budget     = { monthlyUsd = 500 }
        storage    = { bucket = "daimyo-${each.key}" }
        secrets    = { openbaoPath = "orgs/${each.key}" }
      },
      each.key == "seven30" ? {
        issuers = [
          {
            issuer    = "https://auth.shdr.ch/realms/seven30"
            audiences = ["daimyo"]
            principal = { claim = "preferred_username", prefix = "user:" }
            groups    = { claim = "groups" }
          },
          {
            issuer         = "https://gitlab.home.shdr.ch"
            audiences      = ["daimyo"]
            principal      = { claim = "project_path", prefix = "ci:" }
            requiredClaims = { namespace_path = "seven30*" }
          },
        ]
      } : {}
    )
  })
}

resource "kubectl_manifest" "daimyo_project" {
  for_each   = local.daimyo_orgs
  depends_on = [kubectl_manifest.daimyo_org]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Project"
    metadata = {
      name      = each.key
      namespace = "org-${each.key}"
      labels    = local.daimyo_labels
    }
    spec = {
      description = each.key == "personal" ? "Personal agents." : "Seven30 agents."
    }
  })
}

resource "kubectl_manifest" "daimyo_echo_bundle" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "ConfigBundle"
    metadata = {
      name      = "echo"
      namespace = "org-personal"
      labels    = local.daimyo_labels
    }
    spec = {
      versions = [
        { version = 1, contents = { model = local.daimyo_echo_model } },
      ]
    }
  })
}

resource "kubectl_manifest" "daimyo_echo_agent" {
  depends_on = [kubectl_manifest.daimyo_echo_bundle]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "echo"
      namespace = "org-personal"
      labels    = local.daimyo_labels
    }
    spec = {
      project     = "personal"
      description = "Echoes its input."
      contract    = "v1"
      image       = local.daimyo_echo_image
      resources   = { cpu = "250m", memory = "256Mi", workspace = "512Mi" }
      operations = [
        {
          name        = "say"
          inputSchema = { type = "object" }
          outputSchema = {
            type       = "object"
            required   = ["echo"]
            properties = { echo = { type = "object" } }
          }
        },
      ]
      config = { bundle = "echo", version = 1 }
      grants = [
        { name = "models", model = { models = [local.daimyo_echo_model], budgetUsd = 1 } },
      ]
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

# Migrations: the server does NOT migrate on boot (the Deployment runs
# `serve` without `--migrate`). Before a helm_release bump that ships a new
# migration, run a one-off Job built from the live Deployment's pod template
# (same SA, render-config initContainer and volumes) with the new server
# image and args `--config /etc/daimyo/daimyo.toml serve --roles none
# --migrate`; it logs "migrations applied" and exits 0. 0008 (task/approval
# renames) ran this way as Job daimyo-migrate-0008.
