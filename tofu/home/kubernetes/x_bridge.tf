# =============================================================================
# x-bridge — read-only X/Twitter bridge
# =============================================================================
# Sibling repo ../x-bridge (GitLab so/x-bridge) owns the code and image. It
# drives a Deskplane `chrome-cdp` session over CDP (through deskplane-serve's
# /api/sessions/{n}/cdp proxy), stores what it reads in Postgres, and serves it
# through an OIDC-protected API at https://x-bridge.home.shdr.ch.
#
# Callers authenticate with Keycloak access tokens from realm `aether`
# (keycloak.tf keycloak_openid_client.x_bridge, device grant, `aud: x-bridge`);
# only the operator's subject (operator_oidc_subject) may use the API.
#
# Deskplane access: a static API token for `svc:x-bridge`, limited to
# /api/sessions, is minted in deskplane.tf (random_password.deskplane_x_bridge_token)
# and copied into this namespace as Secret x-bridge-deskplane-token.
#
# Single replica, Recreate: one worker per database (advisory lock) and one
# browser session.
#
# Image: :latest in the GitLab registry, rolled by Keel when CI pushes a new
# digest (keel.tf), like instacart-mcp.

locals {
  x_bridge_ns     = module.namespace["x-bridge"].name
  x_bridge_host   = "x-bridge.home.shdr.ch"
  x_bridge_port   = 8080
  x_bridge_labels = { app = "x-bridge" }
  x_bridge_image  = "${local.gitlab_registry_host}/so/x-bridge:latest"

  x_bridge_cnpg     = "x-bridge-pg"
  x_bridge_database = "app"
  # CNPG generates this Secret (bootstrap.initdb without `secret`); key `uri`
  # is the full connection URI for the owner role.
  x_bridge_cnpg_app_secret = "${local.x_bridge_cnpg}-app"

  x_bridge_deskplane_url     = "http://deskplane.deskplane.svc.cluster.local"
  x_bridge_deskplane_session = "x-bridge"
  x_bridge_oidc_issuer       = "https://auth.shdr.ch/realms/aether"
  x_bridge_oidc_audience     = "x-bridge"
  x_bridge_otlp_endpoint     = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318"
}

# --- Secrets -----------------------------------------------------------------

resource "kubernetes_secret_v1" "x_bridge_gitlab_registry" {
  depends_on = [module.namespace["x-bridge"]]

  metadata {
    name      = "x-bridge-gitlab-registry"
    namespace = local.x_bridge_ns
    labels    = local.x_bridge_labels
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.gitlab_registry_host) = {
          username = var.secrets["gitlab.root_email"]
          password = var.secrets["gitlab.root_password"]
          auth     = base64encode("${var.secrets["gitlab.root_email"]}:${var.secrets["gitlab.root_password"]}")
        }
      }
    })
  }
}

# Same value as the Deskplane-side token Secret (deskplane.tf), so both sides
# always agree.
resource "kubernetes_secret_v1" "x_bridge_deskplane_token" {
  depends_on = [module.namespace["x-bridge"]]

  metadata {
    name      = "x-bridge-deskplane-token"
    namespace = local.x_bridge_ns
    labels    = local.x_bridge_labels
  }

  type = "Opaque"
  data = {
    token = random_password.deskplane_x_bridge_token.result
  }
}

# =============================================================================
# Postgres (CNPG)
# =============================================================================
# Fresh database: no import, no externalClusters. CNPG generates the owner
# credentials in Secret x-bridge-pg-app (keys include `uri`).

resource "kubectl_manifest" "x_bridge_cnpg_cluster" {
  depends_on = [
    helm_release.cnpg,
    helm_release.cnpg_barman_cloud,
    kubectl_manifest.cnpg_require_ceph_rbd_storage,
    kubectl_manifest.cnpg_barman_object_store["x-bridge"],
  ]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.x_bridge_cnpg
      namespace = local.x_bridge_ns
      labels    = local.x_bridge_labels
    }
    spec = {
      instances            = 1
      smartShutdownTimeout = local.cnpg_smart_shutdown_timeout
      enablePDB            = !local.cnpg_node_maintenance
      imageName            = "ghcr.io/cloudnative-pg/postgresql:17.9"
      storage = {
        size         = "5Gi"
        storageClass = local.cnpg_storage_class
      }
      plugins = local.cnpg_plugin_specs["x-bridge"]
      bootstrap = {
        initdb = {
          database = local.x_bridge_database
          owner    = "app"
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# x-bridge app
# =============================================================================

resource "kubernetes_deployment_v1" "x_bridge" {
  depends_on = [
    kubectl_manifest.x_bridge_cnpg_cluster,
    kubernetes_secret_v1.x_bridge_gitlab_registry,
    kubernetes_secret_v1.x_bridge_deskplane_token,
    helm_release.deskplane,
  ]

  metadata {
    name      = "x-bridge"
    namespace = local.x_bridge_ns
    labels    = local.x_bridge_labels
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.x_bridge_labels
    }

    template {
      metadata {
        labels = local.x_bridge_labels
      }

      spec {
        enable_service_links            = false
        automount_service_account_token = false

        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }

        security_context {
          run_as_user     = 10001
          run_as_group    = 10001
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        image_pull_secrets {
          name = kubernetes_secret_v1.x_bridge_gitlab_registry.metadata[0].name
        }

        container {
          name              = "x-bridge"
          image             = local.x_bridge_image
          image_pull_policy = "Always"
          args              = ["serve"]

          port {
            container_port = local.x_bridge_port
            name           = "http"
          }

          env {
            name = "XB_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = local.x_bridge_cnpg_app_secret
                key  = "uri"
              }
            }
          }
          env {
            name  = "XB_DESKPLANE_URL"
            value = local.x_bridge_deskplane_url
          }
          env {
            name = "XB_DESKPLANE_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.x_bridge_deskplane_token.metadata[0].name
                key  = "token"
              }
            }
          }
          env {
            name  = "XB_DESKPLANE_SESSION"
            value = local.x_bridge_deskplane_session
          }
          env {
            name  = "XB_OIDC_ISSUER"
            value = local.x_bridge_oidc_issuer
          }
          env {
            name  = "XB_OIDC_AUDIENCE"
            value = local.x_bridge_oidc_audience
          }
          env {
            name  = "XB_OPERATOR_SUBJECTS"
            value = var.operator_oidc_subject
          }
          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = local.x_bridge_otlp_endpoint
          }
          env {
            name  = "OTEL_SERVICE_NAME"
            value = "x-bridge"
          }
          env {
            name  = "OTEL_RESOURCE_ATTRIBUTES"
            value = "service.namespace=x-bridge,deployment.environment=home"
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = local.x_bridge_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.x_bridge_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            failure_threshold     = 5
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Kyverno owns priorityClassName via namespace-tier defaulting.
      spec[0].template[0].spec[0].priority_class_name,
      # Keel records force-update time on the pod template.
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }
}

resource "kubernetes_service_v1" "x_bridge" {
  metadata {
    name      = "x-bridge"
    namespace = local.x_bridge_ns
    labels    = local.x_bridge_labels
  }

  spec {
    selector = local.x_bridge_labels

    port {
      port        = 80
      target_port = local.x_bridge_port
      name        = "http"
    }
  }
}

# =============================================================================
# HTTPRoute — Gateway API
# =============================================================================

resource "kubernetes_manifest" "x_bridge_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.x_bridge]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "x-bridge", namespace = local.x_bridge_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.x_bridge_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [{ name = "X-Forwarded-Proto", value = "https" }]
          }
        }]
        backendRefs = [{ name = "x-bridge", port = 80 }]
      }]
    }
  }
}

# =============================================================================
# CiliumNetworkPolicy — default-deny for the app pod only
# =============================================================================
# Scoped to the x-bridge pod (not the namespace) so the CNPG instance keeps the
# egress it needs for WAL archiving to SeaweedFS S3. Ports are the post-DNAT
# backend ports (deskplane-serve listens on 8080 behind Service port 80).
# DNS and kube-apiserver rules come from aether-cluster-baseline as well; the
# explicit DNS rule is here because toFQDNs requires the proxy-visible lookup.

resource "kubernetes_manifest" "x_bridge_network" {
  depends_on = [
    helm_release.cilium,
    kubernetes_manifest.cilium_cluster_baseline_network,
  ]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "x-bridge"
      namespace = local.x_bridge_ns
    }
    spec = {
      endpointSelector = { matchLabels = local.x_bridge_labels }
      ingress = [
        # API via the gateway.
        {
          fromEntities = ["ingress"]
          toPorts      = [{ ports = [{ port = tostring(local.x_bridge_port), protocol = "TCP" }] }]
        },
      ]
      egress = [
        # kube-dns, with lookups visible to the FQDN policy below.
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
        # deskplane-serve: session control API and CDP proxy.
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.deskplane_namespace
              "app.kubernetes.io/name"      = "deskplane"
              "app.kubernetes.io/component" = "serve"
            }
          }]
          toPorts = [{ ports = [{ port = "8080", protocol = "TCP" }] }]
        },
        # Keycloak: OIDC discovery and JWKS.
        {
          toFQDNs = [{ matchName = "auth.shdr.ch" }]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
        # The namespace's CNPG cluster.
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = local.x_bridge_ns
              "cnpg.io/cluster"             = local.x_bridge_cnpg
            }
          }]
          toPorts = [{ ports = [{ port = "5432", protocol = "TCP" }] }]
        },
        # OTLP/HTTP to the node-local collector.
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = module.namespace["observability"].name
              "app.kubernetes.io/instance"  = "otel-daemonset"
            }
          }]
          toPorts = [{ ports = [{ port = "4318", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
