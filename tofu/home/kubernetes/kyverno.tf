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

locals {
  dockerhub_pull_secret_name    = "dockerhub-creds"
  dockerhub_registry_servers    = toset(["https://index.docker.io/v1/", "https://registry-1.docker.io", "registry-1.docker.io", "https://registry.hub.docker.com", "registry.hub.docker.com", "https://docker.io", "docker.io", "docker.getoutline.com"])
  dockerhub_registry_username   = var.secrets["dockerhub.username"]
  dockerhub_registry_email      = var.secrets["dockerhub.email"]
  dockerhub_registry_pat        = var.secrets["dockerhub.pat"]
  dockerhub_registry_auth_value = base64encode("${local.dockerhub_registry_username}:${local.dockerhub_registry_pat}")
  dockerhub_registry_auths = {
    for server in local.dockerhub_registry_servers : server => {
      username = local.dockerhub_registry_username
      password = local.dockerhub_registry_pat
      email    = local.dockerhub_registry_email
      auth     = local.dockerhub_registry_auth_value
    }
  }
}

resource "kubernetes_secret_v1" "dockerhub_pull_secret_source" {
  depends_on = [helm_release.kyverno]

  metadata {
    name      = local.dockerhub_pull_secret_name
    namespace = helm_release.kyverno.namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = local.dockerhub_registry_auths
    })
  }
}

resource "kubectl_manifest" "kyverno_dockerhub_pull_secret_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:dockerhub-pull-secret"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-admission-controller"  = "true"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
      }
    }
    rules = [{
      apiGroups = [""]
      resources = ["secrets"]
      verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
    }]
  })
}

resource "kubectl_manifest" "kyverno_dockerhub_pull_secret" {
  depends_on = [
    helm_release.kyverno,
    kubectl_manifest.kyverno_dockerhub_pull_secret_rbac,
    kubernetes_secret_v1.dockerhub_pull_secret_source,
  ]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "dockerhub-pull-secret"
      annotations = {
        "policies.kyverno.io/title"       = "Docker Hub Pull Secret"
        "policies.kyverno.io/category"    = "Registry"
        "policies.kyverno.io/subject"     = "Namespace,ServiceAccount,Pod"
        "policies.kyverno.io/description" = "Clone the Docker Hub pull secret into namespaces and attach it to new ServiceAccounts and Pods."
      }
    }
    spec = {
      background = true
      rules = [
        {
          name = "clone-dockerhub-pull-secret"
          match = {
            any = [{
              resources = {
                kinds = ["Namespace"]
              }
            }]
          }
          exclude = {
            any = [{
              resources = {
                names = [helm_release.kyverno.namespace]
              }
            }]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "Secret"
            name        = local.dockerhub_pull_secret_name
            namespace   = "{{ request.object.metadata.name }}"
            clone = {
              namespace = helm_release.kyverno.namespace
              name      = local.dockerhub_pull_secret_name
            }
          }
        },
        {
          name = "add-dockerhub-pull-secret-to-serviceaccounts"
          match = {
            any = [{
              resources = {
                kinds = ["ServiceAccount"]
              }
            }]
          }
          mutate = {
            patchStrategicMerge = {
              imagePullSecrets = [{
                name = local.dockerhub_pull_secret_name
              }]
            }
          }
        },
        {
          name = "add-dockerhub-pull-secret-to-pods"
          match = {
            any = [{
              resources = {
                kinds = ["Pod"]
              }
            }]
          }
          mutate = {
            patchStrategicMerge = {
              spec = {
                imagePullSecrets = [{
                  name = local.dockerhub_pull_secret_name
                }]
              }
            }
          }
        },
      ]
    }
  })
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
