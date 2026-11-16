# =============================================================================
# pop `[db]`: per-project document storage for pop sites
# =============================================================================
# Database `pop_apps` on the existing pop CNPG cluster, served to browsers by
# PostgREST (chart: deploy/helm/pop `apps`) behind pop-origin's /_pop/db.
# pop never creates roles or memberships at runtime: CNPG revokes any
# membership a managed role does not declare, so all four roles are declared
# here (managed roles live in pop.tf's Cluster spec) and pop only creates
# schemas, tables and policies as the database owner.
#
#   pop_apps_admin          LOGIN, owner of pop_apps (pop-api provisioning)
#   pop_apps_web            NOLOGIN, the role every visitor JWT carries
#   pop_apps_authenticator  LOGIN NOINHERIT, member of pop_apps_web (PostgREST)
#   pop_apps_listener       LOGIN (pop-origin LISTEN pop_db change feed)
#
# The HS256 key PostgREST verifies and pop-origin signs with lives in OpenBao
# (pop/apps-jwt-key) and reaches both through one ExternalSecret key, so the
# bytes are identical on both sides.

locals {
  pop_apps_database = "pop_apps"
  pop_apps_roles = {
    admin         = "pop_apps_admin"
    authenticator = "pop_apps_authenticator"
    listener      = "pop_apps_listener"
  }
}

resource "random_password" "pop_apps" {
  for_each = local.pop_apps_roles
  length   = 32
  special  = false
}

# CNPG passwordSecret (username/password) per login role.
resource "kubernetes_secret_v1" "pop_apps_cnpg" {
  for_each   = local.pop_apps_roles
  depends_on = [module.namespace["pop"]]
  metadata {
    name      = "pop-apps-${each.key}-cnpg"
    namespace = local.pop_namespace
  }
  type = "Opaque"
  data = { username = each.value, password = random_password.pop_apps[each.key].result }
}

# Connection URIs the chart consumes (apps.<role>.secretName, key `uri`).
resource "kubernetes_secret_v1" "pop_apps_uri" {
  for_each   = local.pop_apps_roles
  depends_on = [module.namespace["pop"]]
  metadata {
    name      = "pop-apps-${each.key}"
    namespace = local.pop_namespace
  }
  type = "Opaque"
  data = {
    uri = "postgresql://${each.value}:${random_password.pop_apps[each.key].result}@${local.pop_database_host}:5432/${local.pop_apps_database}?sslmode=disable"
  }
}

resource "kubectl_manifest" "pop_apps_database" {
  depends_on = [kubectl_manifest.pop_cnpg_cluster]
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Database"
    metadata   = { name = "pop-apps", namespace = local.pop_namespace }
    spec = {
      name                  = local.pop_apps_database
      owner                 = local.pop_apps_roles.admin
      cluster               = { name = local.pop_database_cluster }
      databaseReclaimPolicy = "retain"
    }
  })
  lifecycle { prevent_destroy = true }
}

# Alphanumeric so the same value is safe as PGRST_JWT_SECRET (env) and as
# the origin's POP_APPS_JWT_KEY_FILE (file); 64 chars ≥ HS256's 32.
resource "random_password" "pop_apps_jwt_key" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "pop_apps_jwt_key" {
  mount     = var.openbao_kv_mount_path
  name      = "pop/apps-jwt-key"
  data_json = jsonencode({ key = random_password.pop_apps_jwt_key.result })
}

resource "kubectl_manifest" "pop_apps_jwt_key" {
  depends_on = [kubectl_manifest.namespace_secret_store["pop"], vault_kv_secret_v2.pop_apps_jwt_key]
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "pop-apps-jwt", namespace = local.pop_namespace }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { kind = "SecretStore", name = "openbao" }
      target          = { name = "pop-apps-jwt", creationPolicy = "Owner" }
      data = [
        { secretKey = "key", remoteRef = { key = "pop/apps-jwt-key", property = "key" } }
      ]
    }
  })
}

# PostgREST accepts requests only from pop-origin (which mints the visitor
# JWTs); its egress to the CNPG primary rides pop-egress's in-namespace rule.
resource "kubernetes_manifest" "pop_postgrest_ingress" {
  depends_on = [helm_release.pop]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata   = { name = "pop-postgrest-ingress", namespace = local.pop_namespace }
    spec = {
      endpointSelector = {
        matchLabels = { "k8s:app.kubernetes.io/component" = "postgrest" }
      }
      ingress = [
        {
          fromEndpoints = [{
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = local.pop_namespace
              "k8s:app.kubernetes.io/component" = "origin"
            }
          }]
          toPorts = [{ ports = [{ port = "3000", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
