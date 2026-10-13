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
  # Server f0a1b5b (tag sessions-evict-warm-files, pipeline 6845): at the
  # org's hot-session limit the least-recently-used idle session goes cold
  # instead of the request being refused (migration 0037), POST
  # /v1/sessions/{id}:warm, read-only session workspace file routes, and SSE
  # responses without the Connection header (HTTP/2). Earlier, 2cdc4d7: task
  # pods start seconds sooner, the `tunnel` grant (§9.5; the Agent CRD gained
  # spec.grants[].tunnel, applied server-side first per docs/ops/upgrades.md).
  # Sidecar 130fd94 (tag tunnel-grant-3, pipeline 6811): the tunnel also
  # reaches dev servers bound to the IPv6 loopback (Vite). Migrations through
  # 0037.
  daimyo_server_tag  = "sha256:750c0dac2604c7e2320647ce7305562f379ff53f17f0477fe9edb8537d607457"
  daimyo_sidecar_tag = "sha256:d6327e4985a9e20ca2c8147f44ca6378c0c42fe125e8e1dc4c8e3f06cc281652"
  # Built-in harness images (Helm config.harness.images). claude-code at
  # 3d67440 (tag harness-answered-end, pipeline 6824): the system prompt is
  # read from a file (an agent's `pkill -f <word>` cannot kill its own
  # harness), and a turn ends once Claude Code has answered even if a
  # background dev server keeps it up. omp at aec2c85 (prompt file). codex and
  # workflow-runner at 82d82a5 (codex MCP approval mode). workflow-runner runs
  # script workflows (§11.5) with no per-project Agent CR.
  daimyo_harness_claude_code_image     = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-harness-claude-code@sha256:7eaf5fe07c4bd8d9aeefa09e5b510b9da10d1b6ec3e74a8d17e23590169abf8e"
  daimyo_harness_codex_image           = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-harness-codex@sha256:8a0193126be261d215b8e38d0269b0546c35c5f72bd30b95f36cc98051fb5596"
  daimyo_harness_omp_image             = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-harness-omp@sha256:e6b294c53be882b1afdfa95b9eab963028b76bd901e814bf8f871b412b4a676c"
  daimyo_harness_workflow_runner_image = "registry.gitlab.home.shdr.ch/so/daimyo/daimyo-harness-workflow-runner@sha256:a6a3094a6c440e8a2574ef3ebdfc6f9825018042309dcbfc1e561481e0482e55"
  # d7e6ec1 echo (pipeline 6422): org personal's echo, attested there.
  daimyo_echo_image = "registry.gitlab.home.shdr.ch/so/daimyo/echo-agent@sha256:fcc3058613f355cefa107d20b1df31f1198fe266d121ebc342190cb47b4a4ca3"
  # 7eaeb9c echo (pipeline 6741, current Python SDK: prompt cancel, no null
  # data part): org qa's echo, attested in qa by the campaign client.
  daimyo_qa_echo_image = "registry.gitlab.home.shdr.ch/so/daimyo/echo-agent@sha256:95af48a0d5280015793bc4c89ed2d105c38a9598453db11cb897540dc36cd22c"
  daimyo_ns            = module.namespace["daimyo-system"].name
  daimyo_host          = "daimyo.home.shdr.ch"
  daimyo_registry_host = "registry.gitlab.home.shdr.ch"
  daimyo_labels        = { app = "daimyo" }
  # The controller reconciles only CRs carrying its instance label
  # (config.controller.instance below); unlabelled CRs are ignored.
  daimyo_instance  = "daimyo"
  daimyo_cr_labels = merge(local.daimyo_labels, { "daimyo.shdr.ch/instance" = local.daimyo_instance })
  # Org `qa` is the venue of the end-to-end test campaign (daimyo repo
  # docs/plans/2026-10-10-e2e-campaign.md); its objects carry this label too.
  daimyo_qa_labels = merge(local.daimyo_cr_labels, { "daimyo.shdr.ch/campaign" = "e2e" })
  # Model alias the bootstrap echo agent's grant names. Must exist in
  # aether's LiteLLM config (litellm_config.yaml.tftpl): a cheap real alias
  # so key minting succeeds even though echo never calls the model.
  daimyo_echo_model = "moira/flash"
  daimyo_orgs       = toset(["personal", "seven30", "qa"])
  # Orgs whose tasks reach Deskplane's MCP server (daimyo_tasks_egress and
  # deskplane_mcp_daimyo_ingress).
  daimyo_deskplane_orgs = ["personal", "qa"]
  # Orgs whose tasks reach pop's MCP server through the Caddy front
  # (daimyo_tasks_egress); pop trusts their task tokens (pop.tf agent_issuers).
  daimyo_pop_orgs    = ["personal"]
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
  depends_on = [module.namespace["personal-tasks"], module.namespace["seven30-tasks"], module.namespace["qa-tasks"]]

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
    # CNPG managed.roles reads the role's login from this Secret: `username`
    # must name the role. The password is a placeholder CNPG overwrites.
    username = "daimyo_api"
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
    # CNPG managed.roles reads the role's login from this Secret: `username`
    # must name the role. The password is a placeholder CNPG overwrites.
    username = "daimyo_engine"
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

# OpenBao token for the Transit signer + KV secrets reader: a periodic token
# with the daimyo-server policy (openbao_daimyo.tf), stored here, never in
# values. Mint it as an ORPHAN (`auth/token/create-orphan`, period 768h): a
# child of the deploy credential is revoked when that 12h credential expires
# (2026-10-10 outage). The chart's render-config init container copies the
# token at pod start, so after `kubectl patch secret daimyo-openbao` run
# `kubectl rollout restart deploy/daimyo-server`. To be replaced by the
# Kubernetes auth role below once the server supports it.
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

  triggers_replace = ["daimyo-personal,daimyo-seven30,daimyo-qa,daimyo-backups"]

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
      S3_BUCKETS                = "daimyo-personal daimyo-seven30 daimyo-qa daimyo-backups"
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
    module.namespace["org-qa"],
    module.namespace["personal-tasks"],
    module.namespace["seven30-tasks"],
    module.namespace["qa-tasks"],
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
      # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY as env; never in the ConfigMap.
      s3 = kubernetes_secret_v1.daimyo_s3.metadata[0].name
    }
    secretFiles = {
      litellmAdminKey = {
        secretName = kubernetes_secret_v1.daimyo_litellm.metadata[0].name
        key        = "admin-key"
        mountPath  = "/etc/daimyo/secrets/litellm-admin-key"
      }
    }
    # OpenBao via the server ServiceAccount (role in openbao_daimyo.tf): a
    # projected token, logged in and renewed by the server; no standing token.
    openbao = {
      auth = "kubernetes"
      kubernetesAuth = {
        mount    = "kubernetes-aether"
        role     = "aether-k8s-daimyo-server" # vault_kubernetes_auth_backend_role.daimyo_server (tofu/home)
        audience = "https://bao.home.shdr.ch"
      }
    }
    config = {
      publicBaseUrl = "https://daimyo.home.shdr.ch"
      listen        = "0.0.0.0:8080"
      apiUpstream   = "http://daimyo-api.daimyo-system.svc:80"
      # The controller reconciles only CRs labelled with this instance
      # (local.daimyo_cr_labels); set explicitly rather than inheriting the
      # release fullname.
      controller = { instance = local.daimyo_instance }
      harness = {
        images = {
          "claude-code"     = local.daimyo_harness_claude_code_image
          "codex"           = local.daimyo_harness_codex_image
          "omp"             = local.daimyo_harness_omp_image
          "workflow-runner" = local.daimyo_harness_workflow_runner_image
        }
      }
      # Memory search embeds through LiteLLM; the server default alias
      # (text-embedding-3-small) is not served here (litellm_config.yaml.tftpl).
      # The built-in dreamer (§11c.3) runs on the cheap alias.
      memory = {
        embeddingModel   = "aether/qwen3-embedding:0.6b"
        dreamerModel     = "moira/flash"
        dreamerBudgetUsd = 0.25
      }
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
        kind    = "transit"
        pemDir  = null
        orgs    = []
        address = "https://bao.home.shdr.ch"
        # Auth comes from openbao.auth (Kubernetes) above.
      }
      litellm = {
        upstream     = local.daimyo_litellm_upstream
        adminKeyFile = "/etc/daimyo/secrets/litellm-admin-key"
      }
      secrets = {
        kind    = "openbao"
        address = "https://bao.home.shdr.ch"
        mount   = "kv"
        # Auth comes from openbao.auth (Kubernetes) above.
        values = {}
      }
      git = {
        defaultBaseUrl = "https://gitlab.home.shdr.ch"
      }
      metricsListen = "0.0.0.0:9090"
      storage = {
        endpoint = local.daimyo_s3_endpoint
        region   = local.daimyo_s3_region
      }
      # OTLP/HTTP traces to the in-cluster collector (-> Tempo), spec §15.4.
      otel = { endpoint = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318/v1/traces" }
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
      { name = "qa" },
    ]
    # The chart's pre-upgrade hook migrates before any server pod rolls
    # (d58a660): `serve --roles none --migrate` with only the DB secrets, no
    # NATS/OpenBao/SA token, waiting up to 5 min for the database. A failed
    # migration fails the upgrade (atomic) and leaves the old pods running.
    migrate = { enabled = true }
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
      # A JetStream config change (e.g. the per-org accounts) must reach all
      # three pods at once: a one-pod-at-a-time roll splits the cluster and
      # the new pods never pass their JetStream health check. For such a
      # change, first `kubectl patch sts daimyo-nats` to updateStrategy
      # OnDelete (the chart leaves updateStrategy alone), apply, delete all
      # NATS pods together, then patch back to RollingUpdate.
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
      # Default-deny both ways: the only ingress is the engine on 8080, and
      # egress is the allowlist below. Sandboxes share this namespace and are
      # driven through pod exec, not the pod network.
      enableDefaultDeny = {
        egress  = true
        ingress = true
      }
      # Cilium deny rules beat allows from any policy, including the cluster
      # baseline CCNP that lets every pod reach kube-apiserver. Task and
      # sandbox pods have no ServiceAccount token and no business there.
      egressDeny = [
        { toEntities = ["kube-apiserver"] },
      ]
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
      egress = concat([
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
          # Sidecar OTLP/HTTP spans to the node collector (spec §15.4).
          toEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/instance"  = "otel-daemonset"
              "app.kubernetes.io/name"      = "opentelemetry-collector"
              "io.kubernetes.pod.namespace" = "observability"
            }
          }]
          toPorts = [{ ports = [{ port = "4318", protocol = "TCP" }] }]
        },
        {
          # GitLab HTTPS (git grants + registry pulls), npm/pypi (spec §18.1),
          # the GitLab container registry, and SeaweedFS S3 (the sidecar's
          # session workspace snapshot/restore via presigned URLs, §11a.2):
          # FQDN egress, no broad CIDR.
          toFQDNs = [
            { matchName = "gitlab.home.shdr.ch" },
            { matchName = "registry.gitlab.home.shdr.ch" },
            { matchName = "registry.npmjs.org" },
            { matchName = "registry.yarnpkg.com" },
            { matchName = "pypi.org" },
            { matchName = "files.pythonhosted.org" },
            { matchName = "s3.seaweed.home.shdr.ch" },
          ]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
        ], [
        # Deskplane's MCP server (the researcher agent's `web` MCP grant;
        # no client auth, so this rule and deskplane_mcp_daimyo_ingress are
        # the whole access boundary). local.daimyo_deskplane_orgs only.
        for org in [each.key] : {
          toEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"      = "deskplane"
              "app.kubernetes.io/component" = "mcp"
              "io.kubernetes.pod.namespace" = "deskplane"
            }
          }]
          toPorts = [{ ports = [{ port = "8100", protocol = "TCP" }] }]
        } if contains(local.daimyo_deskplane_orgs, org)
        ], [
        # A `tunnel` grant's sidecar client dials Deskplane's tunnel endpoint
        # (wss://<deskplane_host>/api/tunnel) through Caddy with a task token,
        # so the task's own Deskplane browser can load its localhost (§9.5).
        for org in [each.key] : {
          toFQDNs = [{ matchName = local.deskplane_host }]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        } if contains(local.daimyo_deskplane_orgs, org)
        ], [
        # pop's MCP server, https://pop.home.shdr.ch/mcp/<org> through Caddy:
        # the `pop` grant authenticates with a task token pop verifies.
        for org in [each.key] : {
          toFQDNs = [{ matchName = "pop.home.shdr.ch" }]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        } if contains(local.daimyo_pop_orgs, org)
        ], [
        # trip-planner's `flights` grant: fli, in-cluster without client auth
        # (trip_planner.tf), so this rule is its access boundary.
        for org in [each.key] : {
          toEndpoints = [{
            matchLabels = {
              "app"                         = "fli"
              "io.kubernetes.pod.namespace" = local.fli_ns
            }
          }]
          toPorts = [{ ports = [{ port = tostring(local.fli_port), protocol = "TCP" }] }]
        } if contains(local.trip_planner_orgs, org)
        ], [
        # trip-planner's keyless public MCP grants (Kiwi, Skiplagged,
        # trivago, Ferryhopper).
        for org in [each.key] : {
          toFQDNs = [for host in local.trip_planner_public_mcp_hosts : { matchName = host }]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        } if contains(local.trip_planner_orgs, org)
      ])
    }
  }
}

# Sandbox pods share `<org>-tasks` with task pods, so daimyo_tasks_egress
# (endpointSelector {}) lets them reach every service a task may. A sandbox
# has no sidecar and no credentials: it is driven by pod exec, and the code
# in it is the agent's. Deny it the credential-gated in-cluster services
# (Deskplane MCP, LiteLLM, the Daimyo API); Cilium denies beat any allow.
resource "kubernetes_manifest" "daimyo_sandbox_egress_deny" {
  for_each   = local.daimyo_orgs
  depends_on = [helm_release.cilium, helm_release.daimyo]

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "daimyo-sandbox-egress-deny"
      namespace = "${each.key}-tasks"
      labels    = local.daimyo_labels
    }
    spec = {
      endpointSelector = {
        matchExpressions = [{ key = "daimyo.shdr.ch/sandbox", operator = "Exists" }]
      }
      egressDeny = [
        {
          toEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"      = "deskplane"
              "app.kubernetes.io/component" = "mcp"
              "io.kubernetes.pod.namespace" = "deskplane"
            }
          }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "app"                         = "litellm"
              "io.kubernetes.pod.namespace" = "litellm"
            }
          }]
        },
        {
          toEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"      = "daimyo"
              "app.kubernetes.io/component" = "server"
              "io.kubernetes.pod.namespace" = local.daimyo_ns
            }
          }]
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
      labels = each.key == "qa" ? local.daimyo_qa_labels : local.daimyo_cr_labels
    }
    spec = merge(
      {
        # personal: only shdrch. qa: any aether-realm principal (the
        # daimyo-smoke client drives the e2e campaign there).
        issuers = contains(["personal", "qa"], each.key) ? [
          merge(
            {
              issuer    = "https://auth.shdr.ch/realms/aether"
              audiences = ["daimyo"]
              principal = { claim = "preferred_username", prefix = "user:" }
              groups    = { claim = "groups" }
            },
            each.key == "personal" ? { requiredClaims = { preferred_username = "shdrch" } } : {},
          ),
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
      labels    = each.key == "qa" ? local.daimyo_qa_labels : local.daimyo_cr_labels
    }
    spec = {
      description = {
        personal = "Personal agents."
        seven30  = "Seven30 agents."
        qa       = "End-to-end test campaign agents."
      }[each.key]
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
      labels    = local.daimyo_cr_labels
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
      labels    = local.daimyo_cr_labels
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

# Org `qa` (e2e test campaign): the same `echo` agent as personal's, and the
# org Policies campaign agents need. Tasks get no baseline permits (§7.4):
# the baseline only forbids calls and sandbox classes outside the revision's
# `calls`/`sandboxes` and sandboxes the task does not own, so these permits
# (mirroring the daimyo repo's deploy/e2e/m3-agents.yaml) make each agent's
# declared `calls` and `sandboxes` exactly what it may use.
resource "kubectl_manifest" "daimyo_qa_echo_bundle" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "ConfigBundle"
    metadata = {
      name      = "echo"
      namespace = "org-qa"
      labels    = local.daimyo_qa_labels
    }
    spec = {
      versions = [
        { version = 1, contents = { model = local.daimyo_echo_model } },
      ]
    }
  })
}

resource "kubectl_manifest" "daimyo_qa_echo_agent" {
  depends_on = [kubectl_manifest.daimyo_qa_echo_bundle]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "echo"
      namespace = "org-qa"
      labels    = local.daimyo_qa_labels
    }
    spec = {
      project     = "qa"
      description = "Echoes its input."
      contract    = "v1"
      image       = local.daimyo_qa_echo_image
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

resource "kubectl_manifest" "daimyo_qa_policy" {
  for_each = {
    "task-invoke"         = "permit (principal is Task, action == Action::\"agent::invoke\", resource is Operation);"
    "task-sandbox-create" = "permit (principal is Task, action == Action::\"sandbox::create\", resource is SandboxClass);"
    "task-sandbox-use"    = "permit (principal is Task, action in [Action::\"sandbox::use\", Action::\"sandbox::delete\"], resource is Sandbox);"
    # A delegating task follows its child (`GET /v1/tasks/<child>/events`):
    # it may read the tasks it created, and only those.
    "task-read-own" = "permit (principal is Task, action == Action::\"task::read\", resource is Task) when { resource.owner == principal.sub };"
    # The campaign client is a Service; the baseline's workflow permits cover
    # Users only. It starts and reads workflows, and reads and cancels the
    # runs it started (I-D6).
    "service-workflow-start"     = "permit (principal is Service, action in [Action::\"workflow::start\", Action::\"workflow::read\"], resource is Workflow);"
    "service-workflow-run-owner" = "permit (principal is Service, action in [Action::\"workflow::read\", Action::\"workflow::cancel\"], resource is WorkflowRun) when { resource.owner == principal.sub };"
  }
  depends_on = [kubectl_manifest.daimyo_org]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = each.key
      namespace = "org-qa"
      labels    = local.daimyo_qa_labels
    }
    spec = { text = each.value }
  })
}

# `researcher`: a declarative claude-code harness agent (no image of its own;
# compiles onto config.harness.images["claude-code"], and harness revisions
# skip attestation). Models through the sidecar's LiteLLM grant on
# moira/strong; web research through Deskplane's MCP server (the `web` grant,
# bearer token from OpenBao orgs/personal/deskplane, openbao_daimyo.tf; the
# network path is daimyo_tasks_egress and deskplane_mcp_daimyo_ingress).
# Claude Code's own WebSearch is an Anthropic server tool a LiteLLM alias
# cannot serve, so the `web` built-ins stay off.
resource "kubectl_manifest" "daimyo_researcher_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "researcher"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "personal"
      description = "Researches topics on the web and writes cited reports."
      harness = {
        kind         = "claude-code"
        model        = "moira/strong"
        systemPrompt = <<-EOT
          You research topics and write cited reports. Find sources with the
          search_web tool, then read the most relevant ones in full with
          scrape (web pages) or parse_document (PDFs and other documents).
          Prefer primary sources. Cite every claim with the URL you read it
          at, and finish with the report as your answer, followed by the list
          of URLs you used.
        EOT
        tools        = { bash = true, files = true, web = false }
        maxTurns     = 200
      }
      resources  = { cpu = "1", memory = "2Gi", workspace = "2Gi" }
      operations = [{ name = "ask", deadline = "2h" }]
      grants = [
        { name = "models", model = { models = ["moira/strong"], budgetUsd = 5 } },
        {
          name = "web"
          mcp = {
            url = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            auth = {
              secret = {
                secret = { path = "orgs/personal/deskplane", key = "token" }
                header = { name = "Authorization" }
                prefix = "Bearer"
              }
            }
            tools = ["search_web", "scrape", "parse_document"]
          }
        },
        {
          # pop (sites + functions). A Daimyo task token with aud `pop`: pop's
          # aether org trusts this org's issuer as an agent issuer with exactly
          # pop:deploy (pop.tf `agent_issuers`), and its audit records the
          # task as actor and the person who started it from `act`. Reading and
          # uploading a deploy run freely; anything that changes what is live,
          # deletes, or exports form data asks the task's creator (§9.4).
          name = "pop"
          mcp = {
            url  = "https://pop.home.shdr.ch/mcp/aether"
            auth = { taskToken = { audience = "pop" } }
            tools = [
              "projects_list", "deploys_list", "deploy_get", "aliases_list",
              "events_list", "forms_list", "hooks_list", "telemetry_link",
              "deploy_begin", "deploy_files", "deploy_finalize",
              { name = "project_create", policy = "ask" },
              { name = "project_delete", policy = "ask" },
              { name = "alias_set", policy = "ask" },
              { name = "alias_rollback", policy = "ask" },
              { name = "alias_delete", policy = "ask" },
              { name = "hook_add", policy = "ask" },
              { name = "hook_remove", policy = "ask" },
              { name = "forms_export", policy = "ask" },
              { name = "form_file_link", policy = "ask" },
            ]
          }
        },
      ]
      sessions  = { enabled = true }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

# `frontend`: builds web apps and checks them in a real browser. Its dev
# server runs on the task's localhost; the `browser` grant is Deskplane's MCP
# as this task (a task token Deskplane trusts, deskplane.tf
# deskplane_workload_issuers), and the `browser-tunnel` grant lets that
# browser load the task's localhost (§9.5) with no inbound path to the pod.
# The session is watchable live at the navigate result's watch_url. `pop`
# publishes previews as researcher's grant does.
resource "kubectl_manifest" "daimyo_frontend_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "frontend"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "personal"
      description = "Builds web apps and checks them in a real browser while it works."
      harness = {
        kind         = "claude-code"
        model        = "moira/strong"
        systemPrompt = <<-EOT
          You build web front ends. Work in $DAIMYO_WORKSPACE. Run the dev
          server in the background on localhost (for Vite: npx vite --port
          5173). Look at your work in the browser: navigate to
          http://localhost:<port>/ (that browser reaches your localhost),
          take a screenshot, and fix what looks wrong; repeat after changes
          (the dev server's live reload updates the page, so you rarely need
          to navigate again). Report the watch_url the browser tools return
          so the user can watch. Publish a preview with the pop tools only
          when asked.
        EOT
        tools        = { bash = true, files = true, web = false }
        maxTurns     = 200
      }
      resources  = { cpu = "2", memory = "4Gi", workspace = "4Gi" }
      operations = [{ name = "ask", deadline = "2h" }]
      grants = [
        { name = "models", model = { models = ["moira/strong"], budgetUsd = 5 } },
        {
          name = "browser"
          mcp = {
            url  = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            auth = { taskToken = { audience = "deskplane" } }
            tools = [
              "navigate", "screenshot", "click", "double_click", "move", "drag",
              "type_text", "key", "scroll", "wait", "watch_link",
            ]
          }
        },
        {
          name = "browser-tunnel"
          tunnel = {
            url  = "wss://${local.deskplane_host}/api/tunnel"
            auth = { taskToken = { audience = "deskplane" } }
          }
        },
        {
          name = "pop"
          mcp = {
            url  = "https://pop.home.shdr.ch/mcp/aether"
            auth = { taskToken = { audience = "pop" } }
            tools = [
              "projects_list", "deploys_list", "deploy_get", "aliases_list",
              "deploy_begin", "deploy_files", "deploy_finalize",
              { name = "project_create", policy = "ask" },
              { name = "alias_set", policy = "ask" },
              { name = "alias_rollback", policy = "ask" },
            ]
          }
        },
      ]
      sessions  = { enabled = true }
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

# `notes`: the M6 sessions agent Open WebUI reaches through the Daimyo MCP
# connection (openwebui.tf). Image agents need a passing attestation for the
# digest in the org before the revision goes Ready (POST
# /v1/orgs/personal/attestations as an org user; `daimyoctl conformance
# <image> --agent <cr> --attest --org personal` runs the kit and posts it).
resource "kubectl_manifest" "daimyo_notes_agent" {
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "notes"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "personal"
      description = "Keeps a running notes file across a session and recalls earlier turns."
      contract    = "v1"
      image       = "registry.gitlab.home.shdr.ch/so/daimyo/notes-agent@sha256:614091a79afb4917ff2f4a007950096834d49881839fc90912e796528ace072a"
      resources   = { cpu = "250m", memory = "256Mi", workspace = "512Mi" }
      operations = [{
        name        = "note"
        inputSchema = { type = "object" }
        outputSchema = {
          type     = "object"
          required = ["notes", "count"]
          properties = {
            notes    = { type = "array", items = { type = "string" } }
            count    = { type = "integer" }
            answer   = { type = "string" }
            recorded = { type = "string" }
          }
        }
      }]
      endpoints = { stable = { revision = "latest" } }
      sessions  = { enabled = true, idleTtl = "10m", maxLifetime = "7d" }
    }
  })
}

# Deskplane's chart policy (deskplane-mcp-ingress, from helm_release.deskplane
# mcp.ingressFrom) admits only serve, LiteLLM and the collector to MCP :8100.
# NetworkPolicies are additive: this admits the task pods of
# local.daimyo_deskplane_orgs (the researcher's `web` grant, the qa campaign)
# without rolling the Deskplane release. No
# depends_on: the release already exists, and referencing it would pull its
# dependency chain into every targeted plan of this policy.
resource "kubernetes_manifest" "deskplane_mcp_daimyo_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "deskplane-mcp-daimyo-ingress"
      namespace = local.deskplane_namespace
      labels    = local.daimyo_labels
    }
    spec = {
      podSelector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "deskplane"
          "app.kubernetes.io/component" = "mcp"
        }
      }
      policyTypes = ["Ingress"]
      ingress = [{
        from = [for org in local.daimyo_deskplane_orgs : {
          namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "${org}-tasks" } }
        }]
        ports = [{ protocol = "TCP", port = 8100 }]
      }]
    }
  }
}

# Migrations run in the chart's pre-install/pre-upgrade hook (see
# migrate.enabled above and the daimyo repo's docs/ops/upgrades.md).
# Migrations are forward-only: an older server cannot run on a newer schema.
