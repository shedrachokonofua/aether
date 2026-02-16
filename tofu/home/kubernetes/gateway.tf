# =============================================================================
# Gateway API
# =============================================================================
# CRDs installed via kubectl, resources managed by Terraform

# Gateway API CRDs - must exist before GatewayClass/Gateway can be created
resource "null_resource" "gateway_api_crds" {
  depends_on = [helm_release.cilium]

  triggers = {
    version = var.gateway_api_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo '${var.kubeconfig_raw}' > /tmp/talos-kubeconfig
      KUBECONFIG=/tmp/talos-kubeconfig kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/experimental-install.yaml
      rm /tmp/talos-kubeconfig
    EOT
  }
}

# GatewayClass - tells Cilium to handle Gateway resources
resource "kubernetes_manifest" "gateway_class" {
  depends_on = [null_resource.gateway_api_crds]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "cilium"
    }
    spec = {
      controllerName = "io.cilium/gateway-controller"
    }
  }
}

# Main Gateway - ingress point for all HTTP traffic
resource "kubernetes_manifest" "main_gateway" {
  depends_on = [kubernetes_manifest.gateway_class]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "main-gateway"
      namespace = "default"
      annotations = {
        "io.cilium/lb-ipam-ips" = var.workload_vip
      }
    }
    spec = {
      gatewayClassName = "cilium"
      listeners = [{
        name     = "http"
        protocol = "HTTP"
        port     = 80
        hostname = "*.apps.home.shdr.ch"
        allowedRoutes = {
          namespaces = {
            from = "All"
          }
        }
      }]
    }
  }
}
