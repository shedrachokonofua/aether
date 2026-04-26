# =============================================================================
# Kyverno
# =============================================================================
# Policy engine used for scheduler-time guardrails on small ARM/Raspberry Pi
# workers. The ARM policies validate Pod/binding admission requests because
# normal Pod CREATE admission happens before the scheduler has selected a node.

resource "helm_release" "kyverno" {
  depends_on = [helm_release.cilium]

  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  version          = "3.7.2"
  wait             = true
  timeout          = 600

  values = [yamlencode({
    config = {
      # Required for policies which inspect scheduler binding decisions.
      resourceFiltersExclude = [
        "[Binding,*,*]",
        "[Pod/binding,*,*]",
      ]
    }

    admissionController = {
      replicas = 1
      rbac = {
        clusterRole = {
          extraResources = [
            {
              apiGroups = [""]
              resources = ["nodes", "pods"]
              verbs     = ["get", "list"]
            }
          ]
        }
      }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }

    backgroundController = {
      replicas = 1
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }
    }

    cleanupController = {
      replicas = 1
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }

    reportsController = {
      replicas = 1
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }
    }
  })]
}

resource "kubectl_manifest" "kyverno_arm_pool_guardrails" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "arm-pool-guardrails"
      annotations = {
        "pod-policies.kyverno.io/autogen-controllers" = "none"
        "policies.kyverno.io/title"                   = "ARM Pool Guardrails"
        "policies.kyverno.io/category"                = "Scheduling"
        "policies.kyverno.io/subject"                 = "Pod"
        "policies.kyverno.io/description"             = "Only small, explicitly ARM-approved Pods may be bound to Raspberry Pi ARM worker nodes."
      }
    }
    spec = {
      validationFailureAction = "Enforce"
      background              = false
      rules = [
        {
          name = "require-arm-ok-for-arm-pool"
          match = {
            any = [{
              resources = {
                kinds = ["Pod/binding"]
              }
            }]
          }
          exclude = {
            any = [{
              resources = {
                namespaces = ["kube-system", "kube-public", "kube-node-lease", "istio-system", "system", "kyverno"]
              }
            }]
          }
          context = [
            {
              name = "nodePool"
              apiCall = {
                urlPath  = "/api/v1/nodes/{{ request.object.target.name }}"
                jmesPath = "metadata.labels.\"aether.sh/node-pool\" || ''"
              }
            },
            {
              name = "armOk"
              apiCall = {
                urlPath  = "/api/v1/namespaces/{{ request.object.metadata.namespace }}/pods/{{ request.object.metadata.name }}"
                jmesPath = "metadata.labels.\"aether.sh/arm-ok\" || ''"
              }
            }
          ]
          preconditions = {
            all = [{
              key      = "{{ nodePool }}"
              operator = "Equals"
              value    = "arm"
            }]
          }
          validate = {
            message = "Pods scheduled to the ARM pool must be labeled aether.sh/arm-ok=true."
            deny = {
              conditions = {
                any = [{
                  key      = "{{ armOk }}"
                  operator = "NotEquals"
                  value    = "true"
                }]
              }
            }
          }
        },
        {
          name = "require-requests-for-arm-pool"
          match = {
            any = [{
              resources = {
                kinds = ["Pod/binding"]
              }
            }]
          }
          exclude = {
            any = [{
              resources = {
                namespaces = ["kube-system", "kube-public", "kube-node-lease", "istio-system", "system", "kyverno"]
              }
            }]
          }
          context = [
            {
              name = "nodePool"
              apiCall = {
                urlPath  = "/api/v1/nodes/{{ request.object.target.name }}"
                jmesPath = "metadata.labels.\"aether.sh/node-pool\" || ''"
              }
            },
            {
              name = "containers"
              apiCall = {
                urlPath  = "/api/v1/namespaces/{{ request.object.metadata.namespace }}/pods/{{ request.object.metadata.name }}"
                jmesPath = "spec.[ephemeralContainers, initContainers, containers][]"
              }
            }
          ]
          preconditions = {
            all = [{
              key      = "{{ nodePool }}"
              operator = "Equals"
              value    = "arm"
            }]
          }
          validate = {
            message = "Pods scheduled to the ARM pool must set CPU and memory requests on every container."
            foreach = [{
              list = "containers"
              deny = {
                conditions = {
                  any = [
                    {
                      key      = "{{ element.resources.requests.cpu || '' }}"
                      operator = "Equals"
                      value    = ""
                    },
                    {
                      key      = "{{ element.resources.requests.memory || '' }}"
                      operator = "Equals"
                      value    = ""
                    }
                  ]
                }
              }
            }]
          }
        },
        {
          name = "limit-arm-pool-memory-requests"
          match = {
            any = [{
              resources = {
                kinds = ["Pod/binding"]
              }
            }]
          }
          exclude = {
            any = [{
              resources = {
                namespaces = ["kube-system", "kube-public", "kube-node-lease", "istio-system", "system", "kyverno"]
              }
            }]
          }
          context = [
            {
              name = "nodePool"
              apiCall = {
                urlPath  = "/api/v1/nodes/{{ request.object.target.name }}"
                jmesPath = "metadata.labels.\"aether.sh/node-pool\" || ''"
              }
            },
            {
              name = "containers"
              apiCall = {
                urlPath  = "/api/v1/namespaces/{{ request.object.metadata.namespace }}/pods/{{ request.object.metadata.name }}"
                jmesPath = "spec.[ephemeralContainers, initContainers, containers][]"
              }
            }
          ]
          preconditions = {
            all = [{
              key      = "{{ nodePool }}"
              operator = "Equals"
              value    = "arm"
            }]
          }
          validate = {
            message = "Pods scheduled to the ARM pool must request no more than 512Mi memory per container."
            foreach = [{
              list = "containers"
              deny = {
                conditions = {
                  any = [{
                    key      = "{{ element.resources.requests.memory || '0' }}"
                    operator = "GreaterThan"
                    value    = "512Mi"
                  }]
                }
              }
            }]
          }
        }
      ]
    }
  })
}
