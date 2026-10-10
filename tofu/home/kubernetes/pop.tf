locals {
  pop_namespace        = module.namespace["pop"].name
  pop_database         = "pop"
  pop_database_user    = "pop"
  pop_database_cluster = "pop"
  pop_database_host    = "${local.pop_database_cluster}-rw.${local.pop_namespace}.svc.cluster.local"
  pop_otel_endpoint    = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318"

  pop_orgs_file     = "/etc/pop/pop-orgs.json"
  pop_webhook_cidrs = { pods = ["10.244.0.0/16"], services = ["10.96.0.0/12"], lan = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"] }
  pop_orgs = {
    aether = {
      slug               = "aether"
      display_name       = "Aether"
      issuer             = "${var.oidc_issuer_url}/realms/aether"
      audience           = "pop"
      roles_claim        = "roles"
      role_map           = { "pop:deploy" = "pop:deploy", "pop:admin" = "pop:admin" }
      clients            = { cli = "pop-cli", mcp = "pop-mcp", visitor = "pop-visitor", agent = "pop-agent" }
      visitor_secret_ref = { file = "/var/run/pop/visitor/aether" }
      ci_project_paths   = []
    }
    seven30 = {
      slug               = "seven30"
      display_name       = "Seven30"
      issuer             = "${var.oidc_issuer_url}/realms/seven30"
      audience           = "pop"
      roles_claim        = "roles"
      role_map           = { "pop:deploy" = "pop:deploy", "pop:admin" = "pop:admin" }
      clients            = { cli = "pop-cli", mcp = "pop-mcp", visitor = "pop-visitor", agent = "pop-agent" }
      visitor_secret_ref = { file = "/var/run/pop/visitor/seven30" }
      # TODO(operator): add the shdr.ch site repo's GitLab project_path.
      ci_project_paths = ["so/attaining/www"]
    }
  }
}

resource "kubernetes_secret_v1" "pop_db_api" {
  metadata {
    name      = "pop-db-api"
    namespace = local.pop_namespace
  }
  type = "Opaque"
  data = { DATABASE_URL = "postgresql://${local.pop_database_user}:${random_password.pop_database_password.result}@${local.pop_database_host}:5432/${local.pop_database}?sslmode=disable" }
}

resource "kubernetes_secret_v1" "pop_db_origin" {
  metadata {
    name      = "pop-db-origin"
    namespace = local.pop_namespace
  }
  type = "Opaque"
  data = { DATABASE_URL = "postgresql://pop_origin:${random_password.pop_origin_password.result}@${local.pop_database_host}:5432/${local.pop_database}?sslmode=disable" }
}

resource "random_password" "pop_database_password" {
  length  = 32
  special = false
}

resource "random_password" "pop_origin_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "pop_cnpg_app" {
  depends_on = [module.namespace["pop"]]
  metadata {
    name      = "pop-cnpg-app"
    namespace = local.pop_namespace
  }
  type = "Opaque"
  data = { username = local.pop_database_user, password = random_password.pop_database_password.result }
}

resource "kubernetes_secret_v1" "pop_cnpg_origin" {
  depends_on = [module.namespace["pop"]]
  metadata {
    name      = "pop-origin-db"
    namespace = local.pop_namespace
  }
  type = "Opaque"
  data = { username = "pop_origin", password = random_password.pop_origin_password.result }
}

resource "kubectl_manifest" "pop_cnpg_cluster" {
  depends_on = [helm_release.cnpg, kubectl_manifest.cnpg_require_ceph_rbd_storage, kubernetes_secret_v1.pop_cnpg_app, kubernetes_secret_v1.pop_cnpg_origin]
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata   = { name = local.pop_database_cluster, namespace = local.pop_namespace }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      imageName            = "ghcr.io/cloudnative-pg/postgresql:16.14"
      storage              = { size = "10Gi", storageClass = local.cnpg_storage_class }
      bootstrap = { initdb = {
        database = local.pop_database
        owner    = local.pop_database_user
        secret   = { name = kubernetes_secret_v1.pop_cnpg_app.metadata[0].name }
        postInitApplicationSQL = [
          "GRANT SELECT ON ALL TABLES IN SCHEMA public TO pop_origin",
          "ALTER DEFAULT PRIVILEGES FOR ROLE pop IN SCHEMA public GRANT SELECT ON TABLES TO pop_origin",
          "DO $$ BEGIN IF to_regclass('public.aliases') IS NOT NULL AND to_regclass('public.deploys') IS NOT NULL THEN EXECUTE 'GRANT SELECT ON aliases, deploys TO pop_origin'; END IF; END $$",
        ]
      } }
      managed = { roles = [{ name = "pop_origin", login = true, passwordSecret = { name = kubernetes_secret_v1.pop_cnpg_origin.metadata[0].name } }] }
    }
  })
  lifecycle { prevent_destroy = true }
}

resource "terraform_data" "pop_chart" {
  lifecycle {
    precondition {
      condition     = fileexists("${path.module}/../../../../pop/deploy/helm/pop/Chart.yaml")
      error_message = "Expected sibling pop/deploy/helm/pop chart checkout."
    }
  }
}

resource "kubernetes_config_map_v1" "pop_orgs" {
  metadata {
    name      = "pop-orgs"
    namespace = local.pop_namespace
  }
  data = { "pop-orgs.json" = jsonencode({ orgs = values(local.pop_orgs) }) }
}

resource "helm_release" "pop" {
  depends_on = [terraform_data.pop_chart, kubectl_manifest.pop_cnpg_cluster, kubernetes_config_map_v1.pop_orgs, kubectl_manifest.pop_visitor_secrets, kubernetes_secret_v1.pop_gitlab_registry]
  name       = "pop"
  chart      = "${path.module}/../../../../pop/deploy/helm/pop"
  namespace  = local.pop_namespace
  wait       = true
  timeout    = 600
  values = [yamlencode({
    api = {
      image    = { repository = "registry.gitlab.home.shdr.ch/so/pop/pop-api", tag = var.pop_api_image_tag }
      replicas = 2
      port     = 8080
    }
    origin = {
      image         = { repository = "registry.gitlab.home.shdr.ch/so/pop/pop-origin", tag = var.pop_origin_image_tag }
      replicas      = 2
      port          = 8080
      customDomains = ["shdr.ch", "attain.ing"]
    }
    clamd = {
      image     = { repository = "clamav/clamav", tag = "1.4" }
      freshclam = { image = { repository = "clamav/clamav", tag = "1.4" } }
      port      = 3310
    }
    migration = { image = { repository = "registry.gitlab.home.shdr.ch/so/pop/pop-api", tag = var.pop_api_image_tag } }
    serviceAccount = {
      api    = { create = true, name = "pop-api" }
      origin = { create = true, name = "pop-origin" }
    }
    database = {
      api    = { secretName = kubernetes_secret_v1.pop_db_api.metadata[0].name }
      origin = { secretName = kubernetes_secret_v1.pop_db_origin.metadata[0].name }
    }
    awsRoleArn = {
      api    = format("arn:aws:iam::%s:role/pop-api", data.vault_kv_secret_v2.pop_ceph_account.data["account_id"])
      origin = format("arn:aws:iam::%s:role/pop-origin", data.vault_kv_secret_v2.pop_ceph_account.data["account_id"])
    }
    awsStsEndpoint = "https://s3.home.shdr.ch"
    webhookCIDRs   = local.pop_webhook_cidrs
    config         = { webhookInternalAllow = "ntfy.home.shdr.ch" }
    orgs           = { configMap = "pop-orgs", mountPath = local.pop_orgs_file }
    sessionKey     = { secretName = "pop-session-key", mountPath = "/var/run/pop/session.key" }
    webhookKey     = { secretName = "pop-webhook-key", mountPath = "/var/run/pop/webhook.key" }
    visitorSecrets = { externalSecret = "pop-visitor-secrets", mountPath = "/var/run/pop/visitor" }
    otel = {
      endpoint           = local.pop_otel_endpoint
      resourceAttributes = "service.namespace=pop,deployment.environment=home"
    }
    internal = { port = 8081 }
    env = [
      { name = "AWS_ENDPOINT_URL_STS", value = "https://s3.home.shdr.ch" },
      { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = local.pop_otel_endpoint },
    ]
    imagePullSecrets    = [{ name = kubernetes_secret_v1.pop_gitlab_registry.metadata[0].name }]
    podDisruptionBudget = { minAvailable = 1 }
  })]
}

resource "kubectl_manifest" "pop_visitor_secrets" {
  depends_on = [kubectl_manifest.namespace_secret_store["pop"]]
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "pop-visitor-secrets", namespace = local.pop_namespace }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { kind = "SecretStore", name = "openbao" }
      target          = { name = "pop-visitor-secrets", creationPolicy = "Owner" }
      data = [
        { secretKey = "aether", remoteRef = { key = "pop/aether/visitor", property = "client_secret" } },
        { secretKey = "seven30", remoteRef = { key = "pop/seven30/visitor", property = "client_secret" } },
      ]
    }
  })
}

resource "kubernetes_manifest" "pop_control_route" {
  depends_on = [helm_release.pop]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "pop-control", namespace = local.pop_namespace }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default", sectionName = "http" }]
      hostnames  = ["pop.home.shdr.ch"]
      rules = [
        {
          matches = [
            { path = { type = "Exact", value = "/v1" } },
            { path = { type = "PathPrefix", value = "/v1/" } },
            { path = { type = "PathPrefix", value = "/auth" } },
            { path = { type = "Exact", value = "/healthz" } },
            { path = { type = "PathPrefix", value = "/mcp" } },
            { path = { type = "PathPrefix", value = "/.well-known/oauth-protected-resource" } },
          ]
          backendRefs = [{ name = "pop-api", port = 8080 }]
        },
        {
          matches     = [{ path = { type = "PathPrefix", value = "/" } }]
          backendRefs = [{ name = "pop-origin", port = 8080 }]
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "pop_sites_route" {
  depends_on = [helm_release.pop]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "pop-sites", namespace = local.pop_namespace }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default", sectionName = "http" }]
      hostnames  = ["*.pop.home.shdr.ch"]
      rules = [
        {
          matches     = [{ path = { type = "PathPrefix", value = "/" } }]
          backendRefs = [{ name = "pop-origin", port = 8080 }]
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "pop_egress" {
  depends_on = [helm_release.pop]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata   = { name = "pop-egress", namespace = local.pop_namespace }
    spec = {
      endpointSelector = { matchLabels = {} }
      egress = [
        {
          toCIDRSet = [{
            cidr   = "0.0.0.0/0"
            except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]
          }]
          toPorts = [{ ports = [{ port = "80", protocol = "TCP" }, { port = "443", protocol = "TCP" }] }]
        },
        {
          toCIDRSet = [{ cidr = "10.0.2.2/32" }]
          toPorts   = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "kube-system", "k8s:k8s-app" = "kube-dns" } }]
          toPorts     = [{ ports = [{ port = "53", protocol = "UDP" }, { port = "53", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "wasmcloud-system", "k8s:app.kubernetes.io/name" = "nats" } }]
          toPorts     = [{ ports = [{ port = "4222", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = local.pop_namespace, "k8s:cnpg.io/cluster" = "pop" } }]
          toPorts     = [{ ports = [{ port = "5432", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "observability", "k8s:app.kubernetes.io/name" = "opentelemetry-collector" } }]
          toPorts     = [{ ports = [{ port = "4318", protocol = "TCP" }] }]
        },
        {
          toFQDNs = [{ matchName = "database.clamav.net" }]
          toPorts = [{ ports = [{ port = "80", protocol = "TCP" }, { port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}

data "vault_kv_secret_v2" "pop_ceph_account" {
  mount = var.openbao_kv_mount_path
  name  = "aether/ceph-rgw"
}
