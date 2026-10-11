locals {
  pop_namespace        = module.namespace["pop"].name
  pop_database         = "pop"
  pop_database_user    = "pop"
  pop_database_cluster = "pop"
  pop_database_host    = "${local.pop_database_cluster}-rw.${local.pop_namespace}.svc.cluster.local"
  pop_otel_endpoint    = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318"
  # Immutable digests emitted by the pop CI images job (image-digests.env),
  # pinned to so/pop main bcd659c. The precondition on helm_release.pop keeps
  # refusing to apply if either tag is ever reset to null.
  pop_api_image_tag    = "sha256:080cd06bb5c03f81aab617eefb9ee558445a69a46d258ed97078f8f145d3c8e6"
  pop_origin_image_tag = "sha256:8ca1e6959428879116cdede37dd8fec8f49d9951d038c7c98afbc38672f95e7d"

  # Review CF-VisitorE F4: directory mount — kubelet refreshes directory
  # ConfigMap mounts on update but NEVER subPath mounts.
  pop_orgs_file     = "/etc/pop/orgs/pop-orgs.json"
  pop_webhook_cidrs = { pods = ["10.244.0.0/16"], services = ["10.96.0.0/12"], lan = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"] }
  # Org `issuer` is the literal token `iss` pop-api matches per org (spec seed
  # orgs). var.oidc_issuer_url is already the full aether realm URL
  # (https://auth.shdr.ch/realms/aether — talos_cluster.tf), so the realm URLs
  # are spelled out here; suffixing the var would double the /realms path and
  # no Keycloak token would ever match an org.
  pop_orgs = {
    aether = {
      slug               = "aether"
      display_name       = "Aether"
      issuer             = "https://auth.shdr.ch/realms/aether"
      audience           = "pop"
      roles_claim        = "roles"
      role_map           = { "pop:deploy" = "pop:deploy", "pop:admin" = "pop:admin" }
      clients            = { cli = "pop-cli", mcp = "pop-mcp", visitor = "pop-visitor", agent = "pop-agent" }
      visitor_secret_ref = { file = "/var/run/pop/visitor/aether" }
      # shdr.ch belongs to this org: keycloak.tf registers
      # https://shdr.ch/_pop/callback on the aether realm's pop-visitor, so
      # the site's CI id_tokens must be trusted here, not under seven30.
      # TODO(operator): add the shdr.ch site repo's GitLab project_path once
      # the repo exists; until then shdr.ch keeps serving from RGW (the
      # Caddyfile cutover is a separate change).
      ci_project_paths = []
    }
    seven30 = {
      slug               = "seven30"
      display_name       = "Seven30"
      issuer             = "https://auth.shdr.ch/realms/seven30"
      audience           = "pop"
      roles_claim        = "roles"
      role_map           = { "pop:deploy" = "pop:deploy", "pop:admin" = "pop:admin" }
      clients            = { cli = "pop-cli", mcp = "pop-mcp", visitor = "pop-visitor", agent = "pop-agent" }
      visitor_secret_ref = { file = "/var/run/pop/visitor/seven30" }
      # attain.ing static site, published by that repo's CI
      # (https://attain.ing/_pop/callback is on the seven30 realm).
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

# The init SQL goes through a ConfigMap (postInitApplicationSQLRefs), not the
# inline postInitApplicationSQL list: CNPG passes the inline list to the init
# pod as container args, where Kubernetes $(VAR) expansion rewrites `$$` to `$`
# and breaks every dollar-quoted DO block (seen on the first pop bootstrap).
resource "kubernetes_config_map_v1" "pop_cnpg_init_sql" {
  depends_on = [module.namespace["pop"]]
  metadata {
    name      = "pop-cnpg-init-sql"
    namespace = local.pop_namespace
  }
  data = {
    "init.sql" = <<-SQL
      DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pop_origin') THEN CREATE ROLE pop_origin LOGIN; END IF; END $$;
      GRANT SELECT ON ALL TABLES IN SCHEMA public TO pop_origin;
      ALTER DEFAULT PRIVILEGES FOR ROLE ${local.pop_database_user} IN SCHEMA public GRANT SELECT ON TABLES TO pop_origin;
      DO $$ BEGIN IF to_regclass('public.aliases') IS NOT NULL AND to_regclass('public.deploys') IS NOT NULL THEN EXECUTE 'GRANT SELECT ON aliases, deploys TO pop_origin'; END IF; END $$;
    SQL
  }
}

resource "kubectl_manifest" "pop_cnpg_cluster" {
  depends_on = [helm_release.cnpg, kubectl_manifest.cnpg_require_ceph_rbd_storage, kubernetes_secret_v1.pop_cnpg_app, kubernetes_secret_v1.pop_cnpg_origin, kubernetes_config_map_v1.pop_cnpg_init_sql]
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
        postInitApplicationSQLRefs = {
          configMapRefs = [{ name = kubernetes_config_map_v1.pop_cnpg_init_sql.metadata[0].name, key = "init.sql" }]
        }
      } }
      managed = { roles = [{ name = "pop_origin", login = true, passwordSecret = { name = kubernetes_secret_v1.pop_cnpg_origin.metadata[0].name } }] }
      plugins = local.cnpg_plugin_specs["pop"]
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
  depends_on = [terraform_data.pop_chart, kubectl_manifest.pop_cnpg_cluster, kubernetes_config_map_v1.pop_orgs, kubectl_manifest.pop_visitor_secrets, kubectl_manifest.pop_session_key, kubectl_manifest.pop_webhook_key, kubectl_manifest.pop_registry_token, kubernetes_secret_v1.pop_gitlab_registry]
  name       = "pop"
  chart      = "${path.module}/../../../../pop/deploy/helm/pop"
  namespace  = local.pop_namespace
  wait       = true
  lifecycle {
    precondition {
      condition     = local.pop_api_image_tag != null && local.pop_origin_image_tag != null
      error_message = "Pin pop_api_image_tag and pop_origin_image_tag to the digests in pop CI image-digests.env before applying."
    }
  }
  # The chart sizes pop-clamd's readiness probe for a first-run freshclam
  # signature download+load: 30s initialDelay + 15s period × 40 failures
  # ≈ 630s, on top of the pre-install migration Job (CNPG bootstrap +
  # retries). 600s could mark a slow-but-healthy first install failed.
  timeout = 1200
  values = [yamlencode({
    api = {
      image    = { repository = "registry.gitlab.home.shdr.ch/so/pop/pop-api", tag = local.pop_api_image_tag }
      replicas = 2
      port     = 8080
    }
    origin = {
      image    = { repository = "registry.gitlab.home.shdr.ch/so/pop/pop-origin", tag = local.pop_origin_image_tag }
      replicas = 2
      port     = 8080
    }
    # Review CF-VisitorE F2: one shared allowlist rendered as POP_CUSTOM_DOMAINS
    # for BOTH Deployments (api exchange allowlist + origin public-host set).
    customDomains = ["shdr.ch", "attain.ing"]
    clamd = {
      image     = { repository = "clamav/clamav", tag = "1.4" }
      freshclam = { image = { repository = "clamav/clamav", tag = "1.4" } }
      port      = 3310
    }
    migration = { image = { repository = "registry.gitlab.home.shdr.ch/so/pop/pop-api", tag = local.pop_api_image_tag } }
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
    orgs           = { configMap = "pop-orgs", mountPath = "/etc/pop/orgs", fileName = "pop-orgs.json" }
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
    # The GitLab pull secret exists only once SOPS carries the deploy token
    # (wasmcloud.tf); the chart skips imagePullSecrets when the list is empty.
    imagePullSecrets    = local.pop_deploy_token_ready ? [{ name = kubernetes_secret_v1.pop_gitlab_registry[0].metadata[0].name }] : []
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

resource "random_bytes" "pop_session_key" {
  length = 32
}

resource "random_bytes" "pop_webhook_key" {
  length = 32
}

resource "vault_kv_secret_v2" "pop_session_key" {
  mount = var.openbao_kv_mount_path
  name  = "pop/session-key"
  data_json = jsonencode({
    key = random_bytes.pop_session_key.base64
  })
}

resource "vault_kv_secret_v2" "pop_webhook_key" {
  mount = var.openbao_kv_mount_path
  name  = "pop/webhook-key"
  data_json = jsonencode({
    key = random_bytes.pop_webhook_key.base64
  })
}

resource "vault_kv_secret_v2" "pop_registry_token" {
  # Skipped until gitlab.pop_deploy_user / gitlab.pop_deploy_token land in
  # SOPS (see wasmcloud.tf). pop-api needs the materialised token as
  # POP_REGISTRY_TOKEN_FILE (popEnv=prod refuses to start without it), so
  # function image pulls and retention GC stay disabled until the keys exist.
  count = local.pop_deploy_token_ready ? 1 : 0

  mount = var.openbao_kv_mount_path
  name  = "pop/registry-token"
  # Same GitLab deploy token the wasmCloud pull secret uses (read+delete on
  # so/pop), stored `<user>:<token>` as pop-api's POP_REGISTRY_TOKEN_FILE.
  data_json = jsonencode({
    token = "${local.pop_registry_user}:${local.pop_registry_password}"
  })
}

resource "kubectl_manifest" "pop_registry_token" {
  count      = local.pop_deploy_token_ready ? 1 : 0
  depends_on = [kubectl_manifest.namespace_secret_store["pop"], vault_kv_secret_v2.pop_registry_token]
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "pop-registry-token", namespace = local.pop_namespace }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { kind = "SecretStore", name = "openbao" }
      target          = { name = "pop-registry-token", creationPolicy = "Owner" }
      data = [
        { secretKey = "token", remoteRef = { key = "pop/registry-token", property = "token" } }
      ]
    }
  })
}

resource "kubectl_manifest" "pop_session_key" {
  depends_on = [kubectl_manifest.namespace_secret_store["pop"], vault_kv_secret_v2.pop_session_key]
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "pop-session-key", namespace = local.pop_namespace }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { kind = "SecretStore", name = "openbao" }
      target          = { name = "pop-session-key", creationPolicy = "Owner" }
      data = [
        # No decodingStrategy here on purpose: OpenBao stores the base64 text
        # and BOTH pop-api and pop-origin read SESSION_KEY_FILE raw
        # (std::fs::read) and use it as an arbitrary-length HMAC key, so every
        # consumer derives identical MACs from the same 44 mounted bytes.
        { secretKey = "key", remoteRef = { key = "pop/session-key", property = "key" } }
      ]
    }
  })
}

resource "kubectl_manifest" "pop_webhook_key" {
  depends_on = [kubectl_manifest.namespace_secret_store["pop"], vault_kv_secret_v2.pop_webhook_key]
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "pop-webhook-key", namespace = local.pop_namespace }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { kind = "SecretStore", name = "openbao" }
      target          = { name = "pop-webhook-key", creationPolicy = "Owner" }
      data = [
        # OpenBao stores random_bytes(...).base64 (44 chars); pop-api reads
        # WEBHOOK_KEY_FILE raw and AeadKey::from_bytes requires exactly 32
        # bytes, so ESO must base64-decode into the Secret.
        { secretKey = "key", remoteRef = { key = "pop/webhook-key", property = "key", decodingStrategy = "Base64" } }
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
      endpointSelector = {
        matchExpressions = [
          { key = "k8s:app.kubernetes.io/component", operator = "NotIn", values = ["clamd"] },
          # The wasmCloud hostgroup pods run untrusted user functions; they get
          # the narrow pop-hostgroup policy below instead of these
          # namespace-wide allowances (spec decision 1).
          { key = "k8s:wasmcloud.com/name", operator = "NotIn", values = ["hostgroup"] },
        ]
      }
      egress = [
        # Review CF-VisitorE F3: origin → pop-api-internal:8081 (session
        # redeem/exchange, forms, challenge) rides this rule. The api pods live
        # in-namespace (10.244/16, inside the excluded 10/8 below), so only an
        # identity-based toEndpoints rule can reach them.
        {
          toEndpoints = [{
            matchLabels = { "k8s:io.kubernetes.pod.namespace" = local.pop_namespace }
          }]
        },
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
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "wasmcloud-system", "k8s:wasmcloud.com/name" = "nats" } }]
          toPorts     = [{ ports = [{ port = "4222", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "observability", "k8s:app.kubernetes.io/name" = "opentelemetry-collector" } }]
          toPorts     = [{ ports = [{ port = "4318", protocol = "TCP" }] }]
        },
      ]
    }
  }
}

# The wasmCloud pop hostgroup runs untrusted user functions, so it gets its
# own narrow policy instead of pop-egress: kube-dns, the wasmCloud NATS
# lattice, the OTel collector, world 80/443 and — SNI-pinned — the home
# GitLab registry through the Caddy front (10.0.2.2, serverNames pattern from
# vcluster_network_policy.tf). Every other cluster and LAN destination stays
# denied unless aether adds it here explicitly.
resource "kubernetes_manifest" "pop_hostgroup" {
  depends_on = [helm_release.wasmcloud]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata   = { name = "pop-hostgroup", namespace = local.pop_namespace }
    spec = {
      # Pod labels the runtime-operator chart puts on hostgroup Deployments
      # (verified via helm template oci://ghcr.io/wasmcloud/charts/runtime-operator
      # --version 2.5.2: templates/runtime/deployment.yaml).
      endpointSelector = {
        matchLabels = {
          "k8s:wasmcloud.com/name"      = "hostgroup"
          "k8s:wasmcloud.com/hostgroup" = "pop"
        }
      }
      ingress = [
        # wasi:http invocations on the host HTTP port (hostGroups[].http.port):
        # pop-origin reaches functions through the selector-less function
        # Services (operator-managed EndpointSlices → host pods :9191).
        {
          fromEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = local.pop_namespace
              "k8s:app.kubernetes.io/component" = "origin"
            }
          }]
          toPorts = [{ ports = [{ port = "9191", protocol = "TCP" }] }]
        },
        # Schedule CronJob pods (pop-api schedules.rs) curl the same Service
        # with X-Pop-Trigger: schedule. Their pod template carries no pop
        # labels, so the Job-controller-stamped job-name label is the only
        # selector they have; the pop-cron-* Jobs are the only long-lived Job
        # pods in this namespace.
        {
          fromEndpoints = [{
            matchExpressions = [{ key = "k8s:job-name", operator = "Exists" }]
          }]
          toPorts = [{ ports = [{ port = "9191", protocol = "TCP" }] }]
        },
      ]
      egress = [
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "kube-system", "k8s:k8s-app" = "kube-dns" } }]
          toPorts = [{
            ports = [{ port = "53", protocol = "UDP" }, { port = "53", protocol = "TCP" }]
            rules = { dns = [{ matchPattern = "*" }] }
          }]
        },
        # wasmCloud NATS lattice (scheduler + data plane).
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "wasmcloud-system", "k8s:wasmcloud.com/name" = "nats" } }]
          toPorts     = [{ ports = [{ port = "4222", protocol = "TCP" }] }]
        },
        # OTel collector for --wasi-otel function telemetry (gRPC + HTTP).
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "observability", "k8s:app.kubernetes.io/name" = "opentelemetry-collector" } }]
          toPorts     = [{ ports = [{ port = "4317", protocol = "TCP" }, { port = "4318", protocol = "TCP" }] }]
        },
        # Public internet only; private/cluster ranges stay excluded.
        {
          toCIDRSet = [{
            cidr   = "0.0.0.0/0"
            except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]
          }]
          toPorts = [{ ports = [{ port = "80", protocol = "TCP" }, { port = "443", protocol = "TCP" }] }]
        },
        # The home Caddy front (10.0.2.2) restricted by SNI to the GitLab
        # registry — the function-component OCI pull path. Every other LAN
        # service behind the same IP stays denied.
        {
          toCIDR = ["10.0.2.2/32"]
          toPorts = [{
            serverNames = [local.pop_registry_host]
            ports       = [{ port = "443", protocol = "TCP" }]
          }]
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "pop_api_ingress" {
  depends_on = [helm_release.pop]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata   = { name = "pop-api-ingress", namespace = local.pop_namespace }
    spec = {
      endpointSelector = {
        matchLabels = { "k8s:app.kubernetes.io/component" = "api" }
      }
      # Review CF-VisitorE F3: the internal listener (8081) is reachable ONLY
      # from the origin (session redeem/exchange, forms, challenge, manifests).
      # Without this rule the pop-egress default-deny drops every such call and
      # every SSO login ends in 503 'pop-api unreachable'.
      ingress = [
        # The Cilium Gateway (entity "ingress", same pattern as assay.tf /
        # celld.tf) delivers HTTPRoute pop-control traffic — /v1, /auth, /mcp,
        # /healthz, /.well-known → pop-api:8080. Without this rule the policy's
        # default-deny drops every CLI, MCP, CI deploy and visitor SSO request.
        {
          fromEntities = ["ingress"]
          toPorts      = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
        },
        {
          fromEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = local.pop_namespace
              "k8s:app.kubernetes.io/component" = "origin"
            }
          }]
          toPorts = [{ ports = [{ port = "8081", protocol = "TCP" }] }]
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "pop_clamd_egress" {
  depends_on = [helm_release.pop]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata   = { name = "pop-clamd-egress", namespace = local.pop_namespace }
    spec = {
      endpointSelector = {
        matchLabels = { "k8s:app.kubernetes.io/component" = "clamd" }
      }
      egress = [
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "kube-system", "k8s:k8s-app" = "kube-dns" } }]
          toPorts = [{
            ports = [{ port = "53", protocol = "UDP" }, { port = "53", protocol = "TCP" }]
            rules = { dns = [{ matchPattern = "*" }] }
          }]
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
