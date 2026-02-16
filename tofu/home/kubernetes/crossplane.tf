# =============================================================================
# Crossplane - Infrastructure Control Plane
# =============================================================================
# Installs Crossplane core and configures providers for self-service infrastructure:
#   - AWS provider: Ceph RGW (S3-compatible) buckets
#   - Keycloak provider: OIDC clients, realms, users

locals {
  crossplane_access_key = var.secrets["ceph.crossplane_access_key"]
  crossplane_secret_key = var.secrets["ceph.crossplane_secret_key"]
}

resource "helm_release" "crossplane" {
  depends_on = [helm_release.cilium]

  name             = "crossplane"
  repository       = "https://charts.crossplane.io/stable"
  chart            = "crossplane"
  namespace        = "crossplane-system"
  create_namespace = true
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
# Crossplane AWS Provider (Ceph RGW / S3-compatible)
# =============================================================================

resource "kubernetes_secret_v1" "crossplane_aws_creds" {
  depends_on = [helm_release.crossplane]

  metadata {
    name      = "crossplane-aws-creds"
    namespace = "crossplane-system"
  }

  data = {
    creds = <<-EOT
      [default]
      aws_access_key_id = ${local.crossplane_access_key}
      aws_secret_access_key = ${local.crossplane_secret_key}
    EOT
  }
}

resource "kubernetes_manifest" "crossplane_provider_aws_s3" {
  depends_on = [helm_release.crossplane]

  manifest = {
    apiVersion = "pkg.crossplane.io/v1"
    kind       = "Provider"
    metadata = {
      name = "provider-aws-s3"
    }
    spec = {
      package = "xpkg.upbound.io/upbound/provider-aws-s3:v1.14.0"
    }
  }
}

resource "kubernetes_manifest" "crossplane_provider_aws_iam" {
  depends_on = [helm_release.crossplane]

  manifest = {
    apiVersion = "pkg.crossplane.io/v1"
    kind       = "Provider"
    metadata = {
      name = "provider-aws-iam"
    }
    spec = {
      package = "xpkg.upbound.io/upbound/provider-aws-iam:v1.14.0"
    }
  }
}

# Wait for Crossplane to install the providers and create CRDs
resource "time_sleep" "wait_for_crossplane_provider_crds" {
  depends_on = [
    kubernetes_manifest.crossplane_provider_aws_s3,
    kubernetes_manifest.crossplane_provider_aws_iam,
  ]

  create_duration = "120s"
}

# Use kubectl_manifest to avoid CRD validation issues at plan time
resource "kubectl_manifest" "crossplane_providerconfig_ceph_rgw" {
  depends_on = [
    kubernetes_secret_v1.crossplane_aws_creds,
    time_sleep.wait_for_crossplane_provider_crds,
  ]

  yaml_body = yamlencode({
    apiVersion = "aws.upbound.io/v1beta1"
    kind       = "ProviderConfig"
    metadata = {
      name = "ceph-rgw"
    }
    spec = {
      credentials = {
        source = "Secret"
        secretRef = {
          namespace = "crossplane-system"
          name      = kubernetes_secret_v1.crossplane_aws_creds.metadata[0].name
          key       = "creds"
        }
      }
      endpoint = {
        url = {
          type   = "Static"
          static = "https://s3.home.shdr.ch"
        }
        services = ["iam", "s3", "sts"]
      }
      skip_credentials_validation = true
      skip_metadata_api_check     = true
      skip_region_validation      = true
      s3_use_path_style           = true
    }
  })
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
