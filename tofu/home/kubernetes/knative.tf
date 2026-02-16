# =============================================================================
# Knative Serving (via Operator)
# =============================================================================
# Serverless platform for scale-to-zero workloads

locals {
  knative_version          = "1.20"
  knative_operator_version = "1.20.0"
  knative_domain           = "apps.home.shdr.ch"
}

# =============================================================================
# Knative Operator (Helm)
# =============================================================================

resource "helm_release" "knative_operator" {
  depends_on = [helm_release.cilium]

  name             = "knative-operator"
  repository       = "https://knative.github.io/operator"
  chart            = "knative-operator"
  namespace        = "knative-operator"
  create_namespace = true
  version          = local.knative_operator_version
  wait             = true
  timeout          = 600
}

# =============================================================================
# Knative Serving Namespace
# =============================================================================

resource "kubernetes_namespace_v1" "knative_serving" {
  depends_on = [helm_release.knative_operator]

  metadata {
    name = "knative-serving"
    labels = {
      "app.kubernetes.io/name"    = "knative-serving"
      "app.kubernetes.io/version" = local.knative_version
    }
  }
}

# =============================================================================
# Gateway API Networking Layer
# =============================================================================

resource "null_resource" "knative_net_gateway_api" {
  depends_on = [kubernetes_namespace_v1.knative_serving, kubernetes_manifest.main_gateway]

  triggers = {
    version = local.knative_operator_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo '${var.kubeconfig_raw}' > /tmp/talos-kubeconfig
      KUBECONFIG=/tmp/talos-kubeconfig kubectl apply -f https://github.com/knative-extensions/net-gateway-api/releases/download/knative-v${local.knative_operator_version}/net-gateway-api.yaml
      rm /tmp/talos-kubeconfig
    EOT
  }
}

# =============================================================================
# KnativeServing Custom Resource
# =============================================================================

locals {
  knative_serving_manifest = {
    apiVersion = "operator.knative.dev/v1beta1"
    kind       = "KnativeServing"
    metadata = {
      name      = "knative-serving"
      namespace = "knative-serving"
    }
    spec = {
      version = local.knative_version
      high-availability = {
        replicas = 3
      }
      config = {
        network = {
          "ingress-class" = "gateway-api.ingress.networking.knative.dev"
        }
        domain = {
          (local.knative_domain) = ""
        }
        gateway = {
          "external-gateways" = yamlencode([{
            name      = "main-gateway"
            namespace = "default"
            service   = local.cilium_gateway_service
          }])
          "local-gateways" = yamlencode([{
            name      = "main-gateway"
            namespace = "default"
            service   = local.cilium_gateway_service
          }])
        }
        autoscaler = {
          "enable-scale-to-zero"       = "true"
          "scale-to-zero-grace-period" = "60s"
          "stable-window"              = "60s"
        }
      }
    }
  }
}

resource "kubectl_manifest" "knative_serving" {
  depends_on = [null_resource.knative_net_gateway_api]

  yaml_body = yamlencode(local.knative_serving_manifest)
}
