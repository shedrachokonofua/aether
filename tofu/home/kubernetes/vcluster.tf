# =============================================================================
# vcluster: Seven30 Studio
# =============================================================================
# Virtual Kubernetes cluster for Seven30 co-founders.
#
# Routing: A Caddy reverse proxy runs inside the vcluster. Co-founders
# manage its Caddyfile (via ConfigMap) to route *.seven30.xyz traffic
# to their apps. A single wildcard HTTPRoute on the host forwards all
# *.seven30.xyz traffic to the synced Caddy service — never needs updating.
#
# Prerequisites:
#   1. Register a GitLab Agent in the seven30/ group (Operate -> K8s clusters)
#   2. Add the token to secrets/secrets.yml as seven30.gitlab_agent_token
#
# Access:
#   kubectl via Tailscale -> k8s.seven30.xyz (Caddy) -> 10.0.3.21 (LB)
#   CI/CD via GitLab Agent (KAS tunnel) running inside the vcluster

locals {
  vcluster_name      = "seven30"
  vcluster_namespace = "vc-seven30"
  vcluster_version   = "0.31.0"

  seven30_gitlab_agent_token = var.secrets["seven30.gitlab_agent_token"]

  seven30_oidc_issuer = "https://auth.shdr.ch/realms/aether"
  seven30_oidc_client = "seven30-kubernetes"

  # Caddy ingress + RBAC bootstrapped inside the vcluster.
  # Co-founders update the ConfigMap from seven30/infra to add routes.
  seven30_bootstrap_manifests = join("\n---\n", [

    # Placeholder Caddyfile — seven30/infra owns the real config
    yamlencode({
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name      = "caddy-ingress"
        namespace = "default"
      }
      data = {
        Caddyfile = <<-CADDYFILE
          :80 {
            respond "Seven30 — no routes configured yet" 503
          }
        CADDYFILE
      }
    }),

    # Caddy reverse proxy deployment
    yamlencode({
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata = {
        name      = "caddy-ingress"
        namespace = "default"
        annotations = {
          "reloader.stakater.com/auto" = "true"
        }
      }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "caddy-ingress" } }
        template = {
          metadata = { labels = { app = "caddy-ingress" } }
          spec = {
            containers = [{
              name  = "caddy"
              image = "caddy:2-alpine"
              ports = [{ containerPort = 80 }]
              volumeMounts = [{
                name      = "caddyfile"
                mountPath = "/etc/caddy/Caddyfile"
                subPath   = "Caddyfile"
              }]
              resources = {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "128Mi" }
              }
            }]
            volumes = [{
              name      = "caddyfile"
              configMap = { name = "caddy-ingress" }
            }]
          }
        }
      }
    }),

    # Caddy ClusterIP service
    yamlencode({
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "caddy-ingress"
        namespace = "default"
      }
      spec = {
        selector = { app = "caddy-ingress" }
        ports    = [{ port = 80, targetPort = 80 }]
      }
    }),

    # RBAC: co-founders + admin get cluster-admin
    yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "ClusterRoleBinding"
      metadata   = { name = "seven30-developers" }
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind     = "ClusterRole"
        name     = "cluster-admin"
      }
      subjects = [
        {
          apiGroup = "rbac.authorization.k8s.io"
          kind     = "Group"
          name     = "seven30-developer"
        },
        {
          apiGroup = "rbac.authorization.k8s.io"
          kind     = "Group"
          name     = "admin"
        },
      ]
    }),

    # RBAC: expose OIDC discovery for OpenBao JWT auth
    yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "ClusterRoleBinding"
      metadata   = { name = "oidc-discovery-public" }
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind     = "ClusterRole"
        name     = "system:service-account-issuer-discovery"
      }
      subjects = [{
        apiGroup = "rbac.authorization.k8s.io"
        kind     = "Group"
        name     = "system:unauthenticated"
      }]
    }),
  ])
}

resource "kubernetes_namespace_v1" "vcluster_seven30" {
  metadata {
    name = local.vcluster_namespace
  }
}

resource "helm_release" "vcluster_seven30" {
  depends_on = [
    helm_release.cilium,
    null_resource.gateway_api_crds,
  ]

  name             = local.vcluster_name
  repository       = "https://charts.loft.sh"
  chart            = "vcluster"
  namespace        = local.vcluster_namespace
  version          = local.vcluster_version
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    # -----------------------------------------------------------------
    # Control Plane
    # -----------------------------------------------------------------
    controlPlane = {
      # TLS SANs so the vcluster cert is valid for our Caddy proxy hostname
      proxy = {
        extraSANs = ["k8s.seven30.xyz", var.vcluster_vip]
      }

      # OIDC authentication via Keycloak
      distro = {
        k8s = {
          # Init container copies K8s binaries; default 256Mi OOMs with v1.34
          resources = {
            limits = {
              memory = "512Mi"
            }
          }
          apiServer = {
            extraArgs = [
              "--oidc-issuer-url=${local.seven30_oidc_issuer}",
              "--oidc-client-id=${local.seven30_oidc_client}",
              "--oidc-username-claim=preferred_username",
              "--oidc-groups-claim=groups",
            ]
          }
        }
      }

      # Expose the API server as a LoadBalancer with a dedicated Cilium L2 IP
      service = {
        annotations = {
          "io.cilium/lb-ipam-ips" = var.vcluster_vip
        }
        spec = {
          type = "LoadBalancer"
        }
      }

      statefulSet = {
        resources = {
          limits = {
            memory = "2Gi"
          }
          requests = {
            cpu    = "200m"
            memory = "512Mi"
          }
        }
      }
    }

    # -----------------------------------------------------------------
    # Bootstrap: Caddy ingress + GitLab Agent inside the vcluster
    # -----------------------------------------------------------------
    experimental = {
      deploy = {
        vcluster = {
          # Caddy reverse proxy — co-founders manage the ConfigMap Caddyfile
          manifests = local.seven30_bootstrap_manifests

          helm = [
            {
              chart = {
                name = "gitlab-agent"
                repo = "https://charts.gitlab.io"
              }
              release = {
                name      = "gitlab-agent"
                namespace = "gitlab-agent"
              }
              values = yamlencode({
                config = {
                  token      = local.seven30_gitlab_agent_token
                  kasAddress = local.gitlab_kas_address
                }
                resources = {
                  requests = { cpu = "50m", memory = "64Mi" }
                  limits   = { cpu = "200m", memory = "256Mi" }
                }
              })
            },
          ]
        }
      }
    }
  })]
}

# =============================================================================
# Wildcard HTTPRoute: *.seven30.xyz -> Caddy inside vcluster
# =============================================================================
# vcluster syncs the caddy-ingress Service from virtual default namespace
# to host vc-seven30 namespace with rewritten name:
#   caddy-ingress-x-default-x-seven30
# This route is set once and never needs updating. Co-founders control
# routing by editing the Caddy ConfigMap inside the vcluster.

resource "kubernetes_manifest" "seven30_httproute" {
  depends_on = [
    kubernetes_manifest.main_gateway,
    helm_release.vcluster_seven30,
  ]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "seven30-ingress"
      namespace = local.vcluster_namespace
    }
    spec = {
      parentRefs = [
        {
          name        = "main-gateway"
          namespace   = "default"
          sectionName = "seven30"
        },
        {
          name        = "main-gateway"
          namespace   = "default"
          sectionName = "seven30-root"
        },
      ]
      hostnames = ["*.seven30.xyz", "seven30.xyz"]
      rules = [{
        backendRefs = [{
          name = "caddy-ingress-x-default-x-${local.vcluster_name}"
          port = 80
        }]
      }]
    }
  }
}
