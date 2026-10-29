# Grafana owns UI state in Postgres; ClickHouse is the only telemetry store.
locals {
  grafana_namespace    = module.namespace["grafana"].name
  grafana_cnpg_cluster = "grafana-cnpg"
  grafana_host         = "grafana.home.shdr.ch"
  grafana_tenants      = { for tenant in yamldecode(file("${path.module}/../../../config/tenants.yml")).tenants : tenant.name => tenant }
  grafana_dashboards   = fileset("${path.module}/grafana/dashboards", "*.json")
  grafana_alert_rules  = toset([for filename in fileset("${path.module}/grafana/alerting/rules", "*.yml") : filename if !endswith(filename, ".prometheus.yml")])
  grafana_clickhouse_json = {
    host            = "clickhouse.home.shdr.ch", port = 443, protocol = "http", secure = true
    defaultDatabase = "otel"
    # Readers are constrained to max_execution_time <= 60s; the plugin's default
    # timeout exceeds that and every query fails with SETTING_CONSTRAINT_VIOLATION.
    queryTimeout = "30"
    logs         = { defaultDatabase = "otel", defaultTable = "otel_logs", otelEnabled = true }
    traces       = { defaultDatabase = "otel", defaultTable = "otel_traces", otelEnabled = true }
  }
  grafana_plugins = {
    grafana-clickhouse-datasource   = "4.21.3"
    yesoreyeram-infinity-datasource = "4.1.1"
    marcusolsson-calendar-panel     = "4.2.4"
    marcusolsson-dynamictext-panel  = "6.3.0"
    volkovlabs-image-panel          = "7.3.3"
    volkovlabs-form-panel           = "6.3.5"
    grafana-clock-panel             = "3.2.4"
    lework-lenav-panel              = "1.1.0"
  }
}


resource "random_password" "grafana_database" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "grafana_database" {
  metadata {
    name      = "grafana-cnpg-app"
    namespace = local.grafana_namespace
  }
  type = "kubernetes.io/basic-auth"
  data = { username = "grafana", password = random_password.grafana_database.result }
}

resource "kubectl_manifest" "grafana_cnpg" {
  depends_on = [helm_release.cnpg, helm_release.cnpg_barman_cloud, kubectl_manifest.cnpg_require_ceph_rbd_storage, kubectl_manifest.cnpg_barman_object_store["grafana"]]
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1", kind = "Cluster"
    metadata = {
      name   = local.grafana_cnpg_cluster, namespace = local.grafana_namespace
      labels = { "app" = "grafana-db", "aether.sh/arm-ok" = "true" }
    }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      imageName            = "ghcr.io/cloudnative-pg/postgresql:16.14"
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "1Gi" }
      }
      storage = { size = "10Gi", storageClass = local.cnpg_storage_class }
      plugins = local.cnpg_plugin_specs["grafana"]
      bootstrap = { initdb = {
        database = "grafana", owner = "grafana"
        secret   = { name = kubernetes_secret_v1.grafana_database.metadata[0].name }
      } }
    }
  })
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_secret_v1" "grafana_credentials" {
  metadata {
    name      = "grafana-credentials"
    namespace = local.grafana_namespace
  }
  data = {
    admin-user     = "admin"
    admin-password = var.secrets["grafana_password"]
    oauth-secret   = var.grafana_oauth_client_secret
  }
}

resource "kubernetes_secret_v1" "grafana_provisioning" {
  metadata {
    name      = "grafana-provisioning-secrets"
    namespace = local.grafana_namespace
  }
  data = {
    "contact-points.yml" = templatefile("${path.module}/grafana/alerting/contact-points.yml.tftpl", {
      inquest_webhook_key            = var.secrets["inquest.webhook_key"]
      uptime_kuma_deadman_push_token = var.secrets["uptime_kuma_deadman_push_token"]
    })
    "datasources.yml" = yamlencode({
      apiVersion = 1
      prune      = true
      datasources = [{
        name           = "ClickHouse", uid = "clickhouse", type = "grafana-clickhouse-datasource"
        orgId          = 1, access = "proxy", isDefault = true, editable = false
        jsonData       = merge(local.grafana_clickhouse_json, { username = "grafana_readonly" })
        secureJsonData = { password = replace(var.secrets["clickhouse.grafana_readonly_password"], "$", "$$") }
      }]
    })
  }
}

resource "kubernetes_config_map_v1" "grafana_dashboard" {
  for_each = local.grafana_dashboards
  metadata {
    name      = "grafana-dashboard-${substr(sha256(each.value), 0, 16)}"
    namespace = local.grafana_namespace
  }
  data = { (each.value) = file("${path.module}/grafana/dashboards/${each.value}") }
}

resource "kubernetes_config_map_v1" "grafana_alert_rule" {
  for_each = local.grafana_alert_rules
  metadata {
    name      = "grafana-alert-${substr(sha256(each.value), 0, 16)}"
    namespace = local.grafana_namespace
  }
  data = { (each.value) = file("${path.module}/grafana/alerting/rules/${each.value}") }
}

resource "kubernetes_config_map_v1" "grafana_policies" {
  metadata {
    name      = "grafana-notification-policies"
    namespace = local.grafana_namespace
  }
  data = { "notification-policies.yml" = file("${path.module}/grafana/alerting/notification-policies.yml") }
}

resource "helm_release" "grafana" {
  depends_on = [kubectl_manifest.grafana_cnpg, kubernetes_manifest.grafana_network]
  name       = "grafana"
  namespace  = local.grafana_namespace
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = "13.5.0"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    fullnameOverride             = "grafana"
    replicas                     = 1
    image                        = { repository = "grafana/grafana", tag = "13.2.3" }
    persistence                  = { enabled = false }
    testFramework                = { enabled = false }
    automountServiceAccountToken = false
    rbac                         = { create = false }
    admin                        = { existingSecret = kubernetes_secret_v1.grafana_credentials.metadata[0].name }
    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { cpu = "2000m", memory = "1Gi" }
    }
    plugins = [for plugin, version in local.grafana_plugins : "${plugin}@${version}@https://grafana.com/api/plugins/${plugin}/versions/${version}/download"]
    envValueFrom = {
      GF_DATABASE_PASSWORD                = { secretKeyRef = { name = kubernetes_secret_v1.grafana_database.metadata[0].name, key = "password" } }
      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = { secretKeyRef = { name = kubernetes_secret_v1.grafana_credentials.metadata[0].name, key = "oauth-secret" } }
    }
    "grafana.ini" = {
      server     = { root_url = "https://${local.grafana_host}" }
      security   = { allow_embedding = true }
      users      = { default_theme = "light", auto_assign_org = false }
      dashboards = { default_home_dashboard_path = "/etc/grafana/provisioning/dashboards/home.json" }
      database = {
        type = "postgres", host = "${local.grafana_cnpg_cluster}-rw:5432", name = "grafana", user = "grafana", ssl_mode = "disable"
      }
      "auth.basic" = { enabled = true }
      "auth.generic_oauth" = {
        enabled                    = true, name = "Aether", allow_sign_up = true, auto_login = true
        allow_assign_grafana_admin = true, client_id = "grafana", scopes = "openid email profile roles"
        email_attribute_path       = "email", login_attribute_path = "preferred_username", name_attribute_path = "name"
        groups_attribute_path      = "realm_access.roles", org_attribute_path = "realm_access.roles"
        auth_url                   = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/auth"
        token_url                  = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/token"
        api_url                    = "https://auth.shdr.ch/realms/aether/protocol/openid-connect/userinfo"
        role_attribute_path        = "contains(realm_access.roles[*], 'admin') && 'GrafanaAdmin' || contains(realm_access.roles[*], 'grafana-editor') && 'Editor' || 'Viewer'"
        org_mapping                = join(" ", concat(["admin:1:Admin"], [for tenant in values(local.grafana_tenants) : "${tenant.keycloak_role}:${tenant.name}:${try(tenant.grafana_role, "Editor")} admin:${tenant.name}:Admin"]))
      }
    }
    dashboardProviders = { "providers.yml" = {
      apiVersion = 1
      providers  = [{ name = "aether", orgId = 1, type = "file", disableDeletion = false, allowUiUpdates = false, updateIntervalSeconds = 30, options = { path = "/etc/grafana/provisioning/dashboards" } }]
    } }
    extraConfigmapMounts = concat(
      [for filename, cm in kubernetes_config_map_v1.grafana_dashboard : {
        name      = cm.metadata[0].name, configMap = cm.metadata[0].name
        mountPath = "/etc/grafana/provisioning/dashboards/${filename}", subPath = filename, readOnly = true
      }],
      [for filename, cm in kubernetes_config_map_v1.grafana_alert_rule : {
        name      = cm.metadata[0].name, configMap = cm.metadata[0].name
        mountPath = "/etc/grafana/provisioning/alerting/${filename}", subPath = filename, readOnly = true
      }],
      [{ name = "notification-policies", configMap = kubernetes_config_map_v1.grafana_policies.metadata[0].name, mountPath = "/etc/grafana/provisioning/alerting/notification-policies.yml", subPath = "notification-policies.yml", readOnly = true }]
    )
    extraSecretMounts = [
      { name = "contact-points", secretName = kubernetes_secret_v1.grafana_provisioning.metadata[0].name, mountPath = "/etc/grafana/provisioning/alerting/contact-points.yml", subPath = "contact-points.yml", readOnly = true },
      { name = "datasources", secretName = kubernetes_secret_v1.grafana_provisioning.metadata[0].name, mountPath = "/etc/grafana/provisioning/datasources/datasources.yml", subPath = "datasources.yml", readOnly = true }
    ]
    # SubPath mounts only update on replacement; provisioning is read at startup.
    podAnnotations = { "checksum/provisioning" = sha256(jsonencode({
      dashboards = { for k, v in kubernetes_config_map_v1.grafana_dashboard : k => v.data }
      rules      = { for k, v in kubernetes_config_map_v1.grafana_alert_rule : k => v.data }
      policies   = kubernetes_config_map_v1.grafana_policies.data
      secrets    = kubernetes_secret_v1.grafana_provisioning.data
    })) }
  })]
}

resource "kubectl_manifest" "grafana_route" {
  depends_on = [helm_release.grafana]
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1", kind = "HTTPRoute"
    metadata   = { name = "grafana", namespace = local.grafana_namespace }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default", sectionName = "http" }]
      hostnames  = [local.grafana_host]
      rules      = [{ backendRefs = [{ name = "grafana", port = 80 }] }]
    }
  })
}

resource "kubernetes_manifest" "grafana_network" {
  depends_on = [kubernetes_manifest.cilium_cluster_baseline_network]
  manifest = {
    apiVersion = "cilium.io/v2", kind = "CiliumNetworkPolicy"
    metadata   = { name = "grafana", namespace = local.grafana_namespace }
    spec = {
      endpointSelector = { matchLabels = { "app.kubernetes.io/name" = "grafana" } }
      ingress          = [{ fromEntities = ["ingress"], toPorts = [{ ports = [{ port = "3000", protocol = "TCP" }] }] }]
      egress = [
        { toCIDR = ["10.0.2.2/32"], toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }] },
        { toEndpoints = [{ matchLabels = { "io.kubernetes.pod.namespace" = local.grafana_namespace, "cnpg.io/cluster" = local.grafana_cnpg_cluster } }], toPorts = [{ ports = [{ port = "5432", protocol = "TCP" }] }] },
        # Plugin ZIPs and public auth/status HTTPS endpoints need internet.
        { toEntities = ["world"], toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }] }
      ]
    }
  }
}

# Apply these after the release and the gateway/Caddy cutover are healthy.
resource "grafana_organization" "tenant" {
  for_each     = local.grafana_tenants
  depends_on   = [helm_release.grafana, kubectl_manifest.grafana_route]
  name         = each.key
  create_users = false
  # Keycloak, not Terraform, owns human membership after first login.
  lifecycle { ignore_changes = [admins, editors, viewers, users_without_access] }
}

resource "grafana_data_source" "tenant" {
  for_each                 = local.grafana_tenants
  org_id                   = grafana_organization.tenant[each.key].org_id
  name                     = "ClickHouse"
  uid                      = "clickhouse"
  type                     = "grafana-clickhouse-datasource"
  is_default               = true
  json_data_encoded        = jsonencode(merge(local.grafana_clickhouse_json, { username = "tenant_${each.key}" }))
  secure_json_data_encoded = jsonencode({ password = var.secrets["clickhouse.tenant_passwords.${each.key}"] })
}

resource "grafana_service_account" "tenant" {
  for_each = local.grafana_tenants
  org_id   = grafana_organization.tenant[each.key].org_id
  name     = "${each.key}-admin"
  role     = "Admin"
}

resource "grafana_service_account_token" "tenant" {
  for_each           = local.grafana_tenants
  name               = "aether-tofu"
  service_account_id = grafana_service_account.tenant[each.key].id
}

resource "vault_kv_secret_v2" "grafana_tenant" {
  for_each = local.grafana_tenants
  mount    = var.openbao_kv_mount_path
  name     = "${each.key}/grafana"
  data_json = jsonencode({
    api_token = grafana_service_account_token.tenant[each.key].key
    org_id    = grafana_organization.tenant[each.key].org_id
    url       = "https://${local.grafana_host}"
  })
}

resource "grafana_service_account" "assay_alerting" {
  depends_on = [helm_release.grafana, kubectl_manifest.grafana_route]
  org_id     = "1"
  name       = "assay-alerting-admin"
  role       = "Admin"
}

resource "grafana_service_account_token" "assay_alerting" {
  name               = "assay-alerting-tofu"
  service_account_id = grafana_service_account.assay_alerting.id
}

resource "vault_kv_secret_v2" "assay_grafana_alerting" {
  mount     = var.openbao_kv_mount_path
  name      = "assay/grafana-alerting"
  data_json = jsonencode({ api_token = grafana_service_account_token.assay_alerting.key, org_id = 1, url = "https://${local.grafana_host}" })
}

resource "grafana_service_account" "holmes" {
  depends_on = [helm_release.grafana, kubectl_manifest.grafana_route]
  org_id     = "1"
  name       = "holmes"
  role       = "Viewer"
}

resource "grafana_service_account_token" "holmes" {
  name               = "aether-tofu"
  service_account_id = grafana_service_account.holmes.id
}

# Orion's Home alerts card and feed `alerts` tool read firing alerts from
# /api/prometheus/grafana/api/v1/alerts (Viewer is enough).
resource "grafana_service_account" "orion" {
  depends_on = [helm_release.grafana, kubectl_manifest.grafana_route]
  org_id     = "1"
  name       = "orion"
  role       = "Viewer"
}

resource "grafana_service_account_token" "orion" {
  name               = "orion-tofu"
  service_account_id = grafana_service_account.orion.id
}

resource "grafana_service_account" "automation" {
  depends_on = [helm_release.grafana, kubectl_manifest.grafana_route]
  org_id     = "1"
  name       = "automation"
  role       = "Viewer"
}

resource "grafana_service_account_token" "automation" {
  name               = "automation-tofu"
  service_account_id = grafana_service_account.automation.id
}

resource "vault_kv_secret_v2" "grafana_automation" {
  mount = var.openbao_kv_mount_path
  name  = "aether/grafana-automation"
  data_json = jsonencode({
    api_token = grafana_service_account_token.automation.key
    url       = "https://${local.grafana_host}"
  })
}
