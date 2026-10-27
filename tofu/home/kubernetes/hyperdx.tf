# ClickStack UI only: ClickHouse and ingestion remain on monitoring-stack.
# OSS has local accounts, not OIDC. Internal exposure is deliberate; bootstrap
# the local team with administrators only and do not invite tenant accounts.
locals {
  hyperdx_chart_version           = "3.4.0"
  hyperdx_operators_chart_version = "1.1.0"
  hyperdx_namespace               = module.namespace["hyperdx"].name
}

# Install the MongoDB operator/CRDs before the chart creates MongoDBCommunity.
resource "helm_release" "clickstack_operators" {
  name       = "clickstack-operators"
  repository = "https://clickhouse.github.io/ClickStack-helm-charts"
  chart      = "clickstack-operators"
  version    = local.hyperdx_operators_chart_version
  namespace  = local.hyperdx_namespace
  wait       = true
  timeout    = 600

  values = [file("${path.module}/hyperdx/operators-values.yaml")]
}

resource "random_password" "hyperdx_mongodb" {
  length  = 32
  special = false
}

resource "random_uuid" "hyperdx_api_key" {}

resource "kubernetes_secret_v1" "hyperdx_config" {
  metadata {
    name      = "hyperdx-config"
    namespace = local.hyperdx_namespace
  }

  data = {
    "connections.json" = jsonencode([{
      name     = "aether-clickhouse"
      host     = "https://clickhouse.home.shdr.ch:443"
      port     = 443
      username = "hyperdx_reader"
      password = var.secrets["clickhouse.hyperdx_password"]
    }])
    "sources.json" = file("${path.module}/hyperdx/sources.json")
  }
}

resource "helm_release" "hyperdx" {
  depends_on = [helm_release.clickstack_operators, kubernetes_secret_v1.hyperdx_config]

  name       = "hyperdx"
  repository = "https://clickhouse.github.io/ClickStack-helm-charts"
  chart      = "clickstack"
  version    = local.hyperdx_chart_version
  namespace  = local.hyperdx_namespace
  wait       = true
  timeout    = 900

  values = [
    file("${path.module}/hyperdx/values.yaml"),
    yamlencode({
      hyperdx = {
        secrets = {
          MONGODB_PASSWORD        = random_password.hyperdx_mongodb.result
          HYPERDX_API_KEY         = random_uuid.hyperdx_api_key.result
          CLICKHOUSE_PASSWORD     = ""
          CLICKHOUSE_APP_PASSWORD = ""
        }
        deployment = {
          # Roll the app when provisioned sources or connection credentials change.
          podAnnotations = {
            "aether.shdr.ch/config-checksum" = sha256(jsonencode(kubernetes_secret_v1.hyperdx_config.data))
          }
        }
      }
    }),
  ]
}

resource "kubernetes_manifest" "hyperdx_route" {
  depends_on = [helm_release.hyperdx]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "hyperdx"
      namespace = local.hyperdx_namespace
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = ["hyperdx.home.shdr.ch"]
      rules = [{
        matches = [{ path = { type = "PathPrefix", value = "/" } }]
        # Caddy terminates TLS; the HTTP gateway otherwise reports http to
        # Express, which refuses to issue the Secure session cookie.
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ kind = "Service", name = "hyperdx", port = 3000 }]
      }]
    }
  }
}
