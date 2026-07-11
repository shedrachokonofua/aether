# =============================================================================
# Crossplane - Infrastructure Control Plane
# =============================================================================
# Installs Crossplane core and configures the Keycloak provider (OIDC clients,
# realms, users). S3/IAM provisioning moved to tofu-native (AWS provider -> RGW)
# in 2026-07; see docs/worklogs/crossplane-s3-migration-2026-07.md.

resource "helm_release" "crossplane" {
  depends_on = [helm_release.cilium]

  name             = "crossplane"
  repository       = "https://charts.crossplane.io/stable"
  chart            = "crossplane"
  namespace        = "crossplane-system"
  version          = "2.1.3"
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    metrics = { enabled = true }
    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }
  })]
}

# =============================================================================
# Crossplane Keycloak Provider
# =============================================================================
# Enables self-service OIDC client creation via Kubernetes CRDs.
# Developers can request Keycloak clients by applying YAML manifests.

# Credentials secret in JSON format (provider-keycloak format)
# Uses service account client credentials grant (no username/password needed)
resource "kubernetes_secret_v1" "crossplane_keycloak_creds" {
  depends_on = [helm_release.crossplane]

  metadata {
    name      = "crossplane-keycloak-creds"
    namespace = "crossplane-system"
  }

  data = {
    credentials = jsonencode({
      client_id     = var.keycloak_client_id
      client_secret = var.keycloak_client_secret
      url           = var.keycloak_url
      realm         = "master"
    })
  }

  type = "Opaque"
}

resource "kubernetes_manifest" "crossplane_provider_keycloak" {
  depends_on = [helm_release.crossplane]

  manifest = {
    apiVersion = "pkg.crossplane.io/v1"
    kind       = "Provider"
    metadata = {
      name = "provider-keycloak"
    }
    spec = {
      package = "xpkg.upbound.io/crossplane-contrib/provider-keycloak:v2.7.2"
    }
  }
}

# Wait for Keycloak provider CRDs to be installed
resource "time_sleep" "wait_for_keycloak_provider_crds" {
  depends_on = [kubernetes_manifest.crossplane_provider_keycloak]

  create_duration = "120s"
}

# ProviderConfig for Keycloak - connects to auth.shdr.ch
resource "kubectl_manifest" "crossplane_providerconfig_keycloak" {
  depends_on = [
    kubernetes_secret_v1.crossplane_keycloak_creds,
    time_sleep.wait_for_keycloak_provider_crds,
  ]

  yaml_body = yamlencode({
    apiVersion = "keycloak.crossplane.io/v1beta1"
    kind       = "ProviderConfig"
    metadata = {
      name = "keycloak"
    }
    spec = {
      credentials = {
        source = "Secret"
        secretRef = {
          namespace = "crossplane-system"
          name      = kubernetes_secret_v1.crossplane_keycloak_creds.metadata[0].name
          key       = "credentials"
        }
      }
    }
  })
}
