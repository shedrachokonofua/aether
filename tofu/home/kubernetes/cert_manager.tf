# =============================================================================
# cert-manager + step-ca Integration
# =============================================================================
# Manages certificate lifecycle for Istio Ambient mesh via:
#   cert-manager  → certificate lifecycle manager
#   step-issuer   → fulfills CertificateRequests via step-ca API
#   istio-csr     → replaces istiod's built-in CA, serves SPIFFE certs to ztunnel
#
# All workload mTLS certs chain back to the step-ca root (ca.shdr.ch),
# making step-ca the single root of trust for the entire infrastructure.

# =============================================================================
# step-ca Data Sources
# =============================================================================

data "http" "step_ca_root" {
  url      = "https://ca.shdr.ch/roots.pem"
  insecure = true
}

data "http" "step_ca_provisioners" {
  url      = "https://ca.shdr.ch/provisioners"
  insecure = true
}

locals {
  step_ca_url = "https://ca.shdr.ch"

  step_ca_root_pem = data.http.step_ca_root.response_body

  machine_bootstrap_kid = [
    for p in jsondecode(data.http.step_ca_provisioners.response_body).provisioners :
    p.key.kid if p.name == "machine-bootstrap"
  ][0]

  istio_csr_service = "cert-manager-istio-csr.cert-manager.svc:443"
}

# =============================================================================
# cert-manager
# =============================================================================

resource "helm_release" "cert_manager" {
  depends_on = [helm_release.cilium]

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.17.1"
  wait             = true
  timeout          = 300

  values = [yamlencode({
    crds = { enabled = true }
  })]
}

# =============================================================================
# step-issuer
# =============================================================================

resource "helm_release" "step_issuer" {
  depends_on = [helm_release.cert_manager]

  name             = "step-issuer"
  repository       = "https://smallstep.github.io/helm-charts"
  chart            = "step-issuer"
  namespace        = "cert-manager"
  create_namespace = false
  wait             = true
  timeout          = 300
}

# Provisioner password for step-issuer to authenticate to step-ca
resource "kubernetes_secret_v1" "step_ca_provisioner" {
  depends_on = [kubernetes_namespace_v1.istio_system]

  metadata {
    name      = "step-ca-provisioner"
    namespace = "istio-system"
  }

  data = {
    password = var.secrets["step_ca.provisioner_password"]
  }
}

# StepIssuer in istio-system (where istio-csr creates CertificateRequests)
# Uses kubectl_manifest to avoid CRD validation at plan time (CRD installed by step-issuer chart)
resource "kubectl_manifest" "step_issuer" {
  depends_on = [helm_release.step_issuer, kubernetes_secret_v1.step_ca_provisioner]

  yaml_body = yamlencode({
    apiVersion = "certmanager.step.sm/v1beta1"
    kind       = "StepIssuer"
    metadata = {
      name      = "step-ca"
      namespace = "istio-system"
    }
    spec = {
      url      = local.step_ca_url
      caBundle = base64encode(local.step_ca_root_pem)
      provisioner = {
        name = "machine-bootstrap"
        kid  = local.machine_bootstrap_kid
        passwordRef = {
          name      = kubernetes_secret_v1.step_ca_provisioner.metadata[0].name
          key       = "password"
          namespace = "istio-system"
        }
      }
    }
  })
}

# =============================================================================
# istio-csr
# =============================================================================

# Root CA secret for istio-csr to distribute to workloads
resource "kubernetes_secret_v1" "istio_root_ca" {
  depends_on = [helm_release.cert_manager]

  metadata {
    name      = "istio-root-ca"
    namespace = "cert-manager"
  }

  data = {
    "ca.pem" = local.step_ca_root_pem
  }
}

resource "helm_release" "istio_csr" {
  depends_on = [
    kubectl_manifest.step_issuer,
    kubernetes_secret_v1.istio_root_ca,
  ]

  name             = "cert-manager-istio-csr"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager-istio-csr"
  namespace        = "cert-manager"
  create_namespace = false
  version          = "v0.13.0"
  wait             = true
  timeout          = 300

  values = [yamlencode({
    app = {
      certmanager = {
        issuer = {
          name  = "step-ca"
          kind  = "StepIssuer"
          group = "certmanager.step.sm"
        }
      }
      server = {
        caTrustedNodeAccounts = "istio-system/ztunnel"
      }
      tls = {
        rootCAFile = "/var/run/secrets/istio-csr/ca.pem"
      }
    }
    volumeMounts = [{
      name      = "root-ca"
      mountPath = "/var/run/secrets/istio-csr"
    }]
    volumes = [{
      name = "root-ca"
      secret = {
        secretName = kubernetes_secret_v1.istio_root_ca.metadata[0].name
      }
    }]
  })]
}
