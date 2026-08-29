# =============================================================================
# Knative Serving (via Operator)
# =============================================================================
# Serverless platform for scale-to-zero workloads

locals {
  knative_version          = "1.20.0"
  knative_operator_version = "1.20.0"
  knative_domain           = "home.shdr.ch"
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
  create_namespace = false
  version          = local.knative_operator_version
  wait             = true
  timeout          = 600

  # Sized from 30d Prometheus (container_memory_working_set_bytes): p95 188Mi,
  # max 247Mi, against the chart default 100Mi. This Deployment lands on the 4GB
  # Pi pool, where a 140Mi understatement is what lets the scheduler over-pack a
  # node.
  values = [yamlencode({
    knative_operator = {
      knative_operator = {
        # Keep control planes out of the 4GB Pi pool; chart key verified in
        # knative-operator-v1.20.0 values.yaml.
        affinity = local.off_arm_pool
      }
      operator_webhook = {
        # Merge with the chart's default podAntiAffinity; replacing affinity would drop it.
        affinity = merge(local.off_arm_pool, {
          podAntiAffinity = {
            preferredDuringSchedulingIgnoredDuringExecution = [{
              weight = 100
              podAffinityTerm = {
                labelSelector = { matchLabels = { app = "operator-webhook" } }
                topologyKey   = "kubernetes.io/hostname"
              }
            }]
          }
        })
        resources = {
          requests = {
            memory = "240Mi"
          }
        }
      }
    }
  })]
}

# =============================================================================
# Knative Serving Namespace
# =============================================================================


# =============================================================================
# Gateway API Networking Layer
# =============================================================================

resource "null_resource" "knative_net_gateway_api" {
  depends_on = [module.namespace["knative-serving"], kubernetes_manifest.main_gateway]

  triggers = {
    version                    = local.knative_operator_version
    net_gateway_webhook_memory = "64Mi"
    off_arm_pool               = sha256(jsonencode(local.off_arm_pool))
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo '${var.kubeconfig_raw}' > /tmp/talos-kubeconfig
      KUBECONFIG=/tmp/talos-kubeconfig kubectl apply -f https://github.com/knative-extensions/net-gateway-api/releases/download/knative-v${local.knative_operator_version}/net-gateway-api.yaml
      # Sized from 30d Prometheus p95 40Mi + 20% headroom (was 20Mi).
      KUBECONFIG=/tmp/talos-kubeconfig kubectl -n knative-serving patch deployment net-gateway-api-webhook -p='{"spec":{"template":{"spec":{"containers":[{"name":"webhook","resources":{"requests":{"memory":"64Mi"}}}]}}}}'
      # These two Deployments come from the upstream manifest, not the operator.
      for d in net-gateway-api-controller net-gateway-api-webhook; do
        KUBECONFIG=/tmp/talos-kubeconfig kubectl -n knative-serving patch deployment $d -p='{"spec":{"template":{"spec":{"affinity":${jsonencode(local.off_arm_pool)}}}}}'
      done
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
      # Operator default minAvailable=80% on 3 replicas leaves 0 allowed
      # disruptions (ceil(3*0.8)=3 must be available), which blocks every
      # node drain. 60% allows 1 disruption (ceil(3*0.6)=2 available).
      podDisruptionBudgets = [
        {
          name         = "activator-pdb"
          minAvailable = "60%"
        },
        {
          name         = "webhook-pdb"
          minAvailable = "60%"
        },
      ]
      # Control plane stays off the Pi pool: 19 pods consumed 1180Mi there for
      # zero Knative Services.
      workloads = [
        for name in [
          "activator",
          "autoscaler",
          "autoscaler-hpa",
          "controller",
          "webhook",
          "net-istio-controller",
          "net-istio-webhook",
          ] : merge(
          {
            name     = name
            affinity = local.off_arm_pool
          },
          name == "webhook" ? {
            # Sized from 30d Prometheus p95 55Mi + 20% headroom (chart default
            # 100Mi). This is knative-serving's own webhook; the knative-operator
            # webhook is a different Deployment and is sized in its helm release.
            resources = [{
              container = "webhook"
              requests = {
                memory = "80Mi"
              }
            }]
          } : {}
        )
      ]
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
