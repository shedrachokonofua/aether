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
  create_namespace = false
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

resource "vault_kv_secret_v2" "dockerhub_pull_secret_source" {
  mount = var.openbao_kv_mount_path
  name  = "${local.eso_secret_path_prefix}/${helm_release.kyverno.namespace}/${local.dockerhub_pull_secret_name}"

  data_json = jsonencode({
    ".dockerconfigjson" = jsonencode({
      auths = local.dockerhub_registry_auths
    })
  })
}

resource "kubectl_manifest" "dockerhub_pull_secret_source" {
  depends_on = [
    helm_release.kyverno,
    kubectl_manifest.namespace_secret_store["kyverno"],
    vault_kv_secret_v2.dockerhub_pull_secret_source,
  ]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.dockerhub_pull_secret_name
      namespace = helm_release.kyverno.namespace
      labels = {
        "app.kubernetes.io/managed-by"     = "OpenTofu"
        "generate.kyverno.io/clone-source" = ""
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "SecretStore"
        name = "openbao"
      }
      target = {
        name           = local.dockerhub_pull_secret_name
        creationPolicy = "Owner"
        template = {
          type = "kubernetes.io/dockerconfigjson"
          metadata = {
            labels = {
              "generate.kyverno.io/clone-source" = ""
            }
          }
        }
      }
      data = [{
        secretKey = ".dockerconfigjson"
        remoteRef = {
          key      = "${local.eso_secret_path_prefix}/${helm_release.kyverno.namespace}/${local.dockerhub_pull_secret_name}"
          property = ".dockerconfigjson"
        }
      }]
    }
  })
}

locals {
  # Kyverno's label-gated generator covers established DockerHub namespaces, but
  # these newer namespaces missed clone materialization while their ServiceAccounts
  # were already mutated. Keep this narrow bootstrap until the generator bug is
  # retired or replaced; do not fan this out to every namespace and duplicate the
  # cloned credential in state.
  dockerhub_pull_secret_bootstrap_namespaces = toset([
    "holmesgpt",
    "kestra",
  ])
}

resource "kubernetes_secret_v1" "dockerhub_pull_secret_bootstrap" {
  for_each = local.dockerhub_pull_secret_bootstrap_namespaces

  depends_on = [
    module.namespace,
    kubectl_manifest.dockerhub_pull_secret_source,
  ]

  metadata {
    name      = local.dockerhub_pull_secret_name
    namespace = module.namespace[each.key].name
    labels = {
      "app.kubernetes.io/managed-by"     = "OpenTofu"
      "generate.kyverno.io/clone-source" = ""
    }
  }

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = local.dockerhub_registry_auths
    })
  }

  type = "kubernetes.io/dockerconfigjson"
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

resource "kubectl_manifest" "kyverno_dockerhub_pull_secret_generate" {
  depends_on = [
    helm_release.kyverno,
    kubectl_manifest.kyverno_dockerhub_pull_secret_rbac,
    kubectl_manifest.dockerhub_pull_secret_source,
  ]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "GeneratingPolicy"
    metadata = {
      name = "dockerhub-pull-secret"
      annotations = {
        "policies.kyverno.io/title"       = "Docker Hub Pull Secret"
        "policies.kyverno.io/category"    = "Registry"
        "policies.kyverno.io/subject"     = "Namespace,Secret"
        "policies.kyverno.io/description" = "Clone the Docker Hub pull secret only into namespaces labeled for Docker Hub registry access."
      }
    }
    spec = {
      evaluation = {
        synchronize = {
          enabled = true
        }
        generateExisting = {
          enabled = true
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["namespaces"]
          scope       = "Cluster"
        }]
      }
      matchConditions = [{
        name       = "dockerhub-registry-access"
        expression = "has(object.metadata.labels) && \"aether.shdr.ch/registry-access\" in object.metadata.labels && object.metadata.labels[\"aether.shdr.ch/registry-access\"] == \"dockerhub\""
      }]
      variables = [
        {
          name       = "targetNamespace"
          expression = "object.metadata.name"
        },
        {
          name       = "sourceSecret"
          expression = "resource.Get(\"v1\", \"secrets\", \"${helm_release.kyverno.namespace}\", \"${local.dockerhub_pull_secret_name}\")"
        },
      ]
      generate = [{
        expression = "generator.Apply(variables.targetNamespace, [variables.sourceSecret])"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_dockerhub_pull_secret_serviceaccounts" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "dockerhub-pull-secret-serviceaccounts"
      annotations = {
        "policies.kyverno.io/title"       = "Docker Hub Pull Secret on ServiceAccounts"
        "policies.kyverno.io/category"    = "Registry"
        "policies.kyverno.io/subject"     = "ServiceAccount"
        "policies.kyverno.io/description" = "Attach Docker Hub imagePullSecrets to ServiceAccounts only in namespaces labeled for Docker Hub registry access."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "aether.shdr.ch/registry-access"
            operator = "In"
            values   = ["dockerhub"]
          }]
        }
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE"]
          resources   = ["serviceaccounts"]
          scope       = "Namespaced"
        }]
      }
      matchConditions = [{
        name       = "missing-dockerhub-pull-secret"
        expression = "!has(object.imagePullSecrets) || !object.imagePullSecrets.exists(secret, secret.name == \"${local.dockerhub_pull_secret_name}\")"
      }]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            (!has(object.imagePullSecrets) ? [
              JSONPatch{op: "add", path: "/imagePullSecrets", value: []}
            ] : []) + [
              JSONPatch{op: "add", path: "/imagePullSecrets/-", value: {"name": "${local.dockerhub_pull_secret_name}"}}
            ]
          EOT
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_dockerhub_pull_secret_pods" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "dockerhub-pull-secret-pods"
      annotations = {
        "policies.kyverno.io/title"       = "Docker Hub Pull Secret on Pods"
        "policies.kyverno.io/category"    = "Registry"
        "policies.kyverno.io/subject"     = "Pod"
        "policies.kyverno.io/description" = "Attach Docker Hub imagePullSecrets to Pods only in namespaces labeled for Docker Hub registry access."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "aether.shdr.ch/registry-access"
            operator = "In"
            values   = ["dockerhub"]
          }]
        }
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE"]
          resources   = ["pods"]
          scope       = "Namespaced"
        }]
      }
      matchConditions = [{
        name       = "missing-dockerhub-pull-secret"
        expression = "!has(object.spec.imagePullSecrets) || !object.spec.imagePullSecrets.exists(secret, secret.name == \"${local.dockerhub_pull_secret_name}\")"
      }]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            (!has(object.spec.imagePullSecrets) ? [
              JSONPatch{op: "add", path: "/spec/imagePullSecrets", value: []}
            ] : []) + [
              JSONPatch{op: "add", path: "/spec/imagePullSecrets/-", value: {"name": "${local.dockerhub_pull_secret_name}"}}
            ]
          EOT
        }
      }]
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

resource "kubectl_manifest" "kyverno_arm_ok_daemonset_pods" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "arm-ok-daemonset-pods"
      annotations = {
        "pod-policies.kyverno.io/autogen-controllers" = "none"
        "policies.kyverno.io/title"                   = "ARM OK DaemonSet Pods"
        "policies.kyverno.io/category"                = "Scheduling"
        "policies.kyverno.io/subject"                 = "Pod"
        "policies.kyverno.io/description"             = "Automatically label DaemonSet-owned Pods as ARM-eligible; ARM pool binding guardrails still enforce resource requests and memory ceilings."
      }
    }
    spec = {
      background = false
      rules = [{
        name = "label-daemonset-pods-arm-ok"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        exclude = {
          any = [{
            resources = {
              namespaces = [
                "kube-system",
                "kube-public",
                "kube-node-lease",
                "istio-system",
                "system",
                "kyverno",
                local.aether_k8s_arch_labeler_namespace,
              ]
            }
          }]
        }
        preconditions = {
          all = [
            {
              key      = "{{ request.object.metadata.ownerReferences[].kind || [] }}"
              operator = "AnyIn"
              value    = ["DaemonSet"]
            },
            {
              key      = "{{ request.object.metadata.labels.\"aether.sh/arm-ok\" || '' }}"
              operator = "Equals"
              value    = ""
            }
          ]
        }
        mutate = {
          patchStrategicMerge = {
            metadata = {
              labels = {
                "aether.sh/arm-ok" = "true"
              }
            }
          }
        }
      }]
    }
  })
}

# Trivy Operator creates one scan Pod per workload and one container per image.
# Those containers share the chart-provided /tmp emptyDir; Trivy derives temp
# paths from PID, and every container process starts as PID 1, so one scanner can
# delete /tmp/trivy-* while another scanner still needs it. Give each scan
# container an isolated subPath while leaving the shared /tmp/scan result volume
# untouched. FailurePolicy=Ignore keeps this an observability repair, not an app
# admission dependency.
resource "kubectl_manifest" "kyverno_trivy_scan_pod_tmp_subpaths" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "trivy-scan-pod-tmp-subpaths"
      annotations = {
        "policies.kyverno.io/title"       = "Trivy Scan Pod Tmp Subpaths"
        "policies.kyverno.io/category"    = "Security"
        "policies.kyverno.io/subject"     = "Pod"
        "policies.kyverno.io/description" = "Isolate /tmp for each Trivy vulnerability scan container so multi-container scan jobs cannot race on /tmp/trivy-* cleanup."
      }
    }
    spec = {
      failurePolicy = "Ignore"
      background    = false
      rules = [{
        name = "isolate-scan-container-tmp"
        match = {
          any = [{
            resources = {
              kinds      = ["Pod"]
              namespaces = [local.trivy_operator_namespace]
            }
          }]
        }
        preconditions = {
          all = [
            {
              key      = "{{ starts_with(request.object.metadata.labels.\"job-name\" || '', 'scan-vulnerabilityreport-') }}"
              operator = "Equals"
              value    = true
            },
            {
              key      = "{{ request.object.spec.volumes[?name=='tmp'] | length(@) }}"
              operator = "GreaterThan"
              value    = 0
            }
          ]
        }
        mutate = {
          foreach = [{
            list = "request.object.spec.containers"
            patchesJson6902 = yamlencode([{
              op    = "add"
              path  = "/spec/containers/{{ elementIndex }}/volumeMounts/0/subPathExpr"
              value = "{{ element.name }}"
            }])
          }]
        }
      }]
    }
  })
}


# Force reclaimPolicy=Retain on dynamically-provisioned Ceph PVs. A StorageClass's
# reclaimPolicy is immutable, so rather than maintain a second SC we mutate the PV
# at admission. failurePolicy=Ignore so a Kyverno outage can never block storage
# provisioning (a PV would just be born Delete, as it is today).
resource "kubectl_manifest" "kyverno_ceph_pv_retain" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "ceph-pv-retain-reclaim"
      annotations = {
        "pod-policies.kyverno.io/autogen-controllers" = "none"
        "policies.kyverno.io/title"                   = "Retain Reclaim on Ceph PVs"
        "policies.kyverno.io/category"                = "Storage"
        "policies.kyverno.io/subject"                 = "PersistentVolume"
        "policies.kyverno.io/description"             = "Dynamically-provisioned Ceph (ceph-rbd/cephfs) PersistentVolumes inherit reclaimPolicy=Delete from their StorageClass, so an accidental PVC/namespace delete destroys the underlying RBD image or CephFS subvolume. This mutates new Ceph PVs to Retain at admission."
      }
    }
    spec = {
      background    = false
      failurePolicy = "Ignore"
      rules = [{
        name = "set-retain-on-ceph-pv"
        match = {
          any = [{
            resources = {
              kinds = ["PersistentVolume"]
            }
          }]
        }
        preconditions = {
          all = [
            {
              key      = "{{ request.operation || 'BACKGROUND' }}"
              operator = "Equals"
              value    = "CREATE"
            },
            {
              key      = "{{ request.object.spec.storageClassName || '' }}"
              operator = "AnyIn"
              value    = ["ceph-rbd", "cephfs"]
            }
          ]
        }
        mutate = {
          patchStrategicMerge = {
            spec = {
              persistentVolumeReclaimPolicy = "Retain"
            }
          }
        }
      }]
    }
  })
}

# CEL twin of kyverno_arm_ok_daemonset_pods. The legacy ClusterPolicy remains
# during rollout; this exercises the promoted MutatingPolicy API with equivalent
# fail-open behavior before the deprecated policy is removed.
resource "kubectl_manifest" "kyverno_arm_ok_daemonset_pods_cel" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1alpha1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "arm-ok-daemonset-pods-cel"
      annotations = {
        "policies.kyverno.io/title"       = "ARM OK DaemonSet Pods CEL"
        "policies.kyverno.io/category"    = "Scheduling"
        "policies.kyverno.io/subject"     = "Pod"
        "policies.kyverno.io/description" = "CEL replacement for labeling DaemonSet-owned Pods as ARM-eligible."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE"]
          resources   = ["pods"]
          scope       = "Namespaced"
        }]
      }
      matchConditions = [
        {
          name       = "daemonset-owned"
          expression = "has(object.metadata.ownerReferences) && object.metadata.ownerReferences.exists(owner, owner.kind == \"DaemonSet\")"
        },
        {
          name       = "not-already-arm-ok"
          expression = "!has(object.metadata.labels) || !(\"aether.sh/arm-ok\" in object.metadata.labels) || object.metadata.labels[\"aether.sh/arm-ok\"] != \"true\""
        },
        {
          name       = "not-system-excluded"
          expression = "!(request.namespace in [\"kube-system\", \"kube-public\", \"kube-node-lease\", \"istio-system\", \"system\", \"kyverno\", \"${local.aether_k8s_arch_labeler_namespace}\"])"
        },
      ]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            (!has(object.metadata.labels) ? [
              JSONPatch{op: "add", path: "/metadata/labels", value: {}}
            ] : []) + [
              JSONPatch{op: "add", path: "/metadata/labels/" + jsonpatch.escapeKey("aether.sh/arm-ok"), value: "true"}
            ]
          EOT
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_ceph_pv_retain_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:ceph-pv-retain"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-admission-controller"  = "true"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
        "rbac.kyverno.io/aggregate-to-reports-controller"    = "true"
      }
    }
    rules = [{
      apiGroups = [""]
      resources = ["persistentvolumes"]
      verbs     = ["get", "list", "watch"]
    }]
  })
}

# CEL twin of kyverno_ceph_pv_retain. Kept alongside the legacy ClusterPolicy
# until the CEL policy has soaked, then the legacy Kyverno rule can be deleted.
resource "kubectl_manifest" "kyverno_ceph_pv_retain_cel" {
  depends_on = [helm_release.kyverno, kubectl_manifest.kyverno_ceph_pv_retain_rbac]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1alpha1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "ceph-pv-retain-reclaim-cel"
      annotations = {
        "policies.kyverno.io/title"       = "Retain Reclaim on Ceph PVs CEL"
        "policies.kyverno.io/category"    = "Storage"
        "policies.kyverno.io/subject"     = "PersistentVolume"
        "policies.kyverno.io/description" = "CEL replacement for mutating dynamically-provisioned Ceph PersistentVolumes to Retain."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE"]
          resources   = ["persistentvolumes"]
          scope       = "Cluster"
        }]
      }
      matchConditions = [
        {
          name       = "ceph-storageclass"
          expression = "has(object.spec.storageClassName) && object.spec.storageClassName in [\"ceph-rbd\", \"cephfs\"]"
        },
        {
          name       = "not-already-retain"
          expression = "!has(object.spec.persistentVolumeReclaimPolicy) || object.spec.persistentVolumeReclaimPolicy != \"Retain\""
        },
      ]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            [
              JSONPatch{op: "add", path: "/spec/persistentVolumeReclaimPolicy", value: "Retain"}
            ]
          EOT
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_namespace_limitrange_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:namespace-limitrange"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
      }
    }
    rules = [{
      apiGroups = [""]
      resources = ["limitranges"]
      verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
    }]
  })
}

resource "kubectl_manifest" "kyverno_namespace_limitrange_default" {
  depends_on = [
    helm_release.kyverno,
    kubectl_manifest.kyverno_namespace_limitrange_rbac,
  ]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "GeneratingPolicy"
    metadata = {
      name = "namespace-default-limitrange"
      annotations = {
        "policies.kyverno.io/title"       = "Namespace Default LimitRange"
        "policies.kyverno.io/category"    = "Resource Management"
        "policies.kyverno.io/subject"     = "Namespace,LimitRange"
        "policies.kyverno.io/description" = "Generate a default LimitRange for non-platform namespaces so Pods without explicit requests receive safe baseline resources."
      }
    }
    spec = {
      evaluation = {
        synchronize = {
          enabled = true
        }
        generateExisting = {
          enabled = true
        }
      }
      matchConstraints = {
        objectSelector = {
          matchExpressions = [
            {
              key      = "aether.shdr.ch/tier"
              operator = "Exists"
            },
            {
              key      = "aether.shdr.ch/tier"
              operator = "NotIn"
              values   = ["platform"]
            },
          ]
        }
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["namespaces"]
          scope       = "Cluster"
        }]
      }
      matchConditions = [{
        name       = "non-platform-tier"
        expression = "has(object.metadata.labels) && \"aether.shdr.ch/tier\" in object.metadata.labels && object.metadata.labels[\"aether.shdr.ch/tier\"] != \"platform\" && object.metadata.name != \"sandboxes\""
      }]
      variables = [
        {
          name       = "targetNamespace"
          expression = "object.metadata.name"
        },
        {
          name       = "limitRange"
          expression = <<-EOT
            [
              {
                "apiVersion": dyn("v1"),
                "kind": dyn("LimitRange"),
                "metadata": dyn({
                  "name": "namespace-defaults",
                  "namespace": string(variables.targetNamespace)
                }),
                "spec": dyn({
                  "limits": dyn([
                    dyn({
                      "type": dyn("Container"),
                      "defaultRequest": dyn({
                        "cpu": "100m",
                        "memory": "256Mi"
                      }),
                    })
                  ])
                })
              }
            ]
          EOT
        },
      ]
      generate = [{
        expression = "generator.Apply(variables.targetNamespace, variables.limitRange)"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_namespace_resourcequota_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:namespace-resourcequota"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
      }
    }
    rules = [{
      apiGroups = [""]
      resources = ["resourcequotas"]
      verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
    }]
  })
}

locals {
  namespace_resourcequota_guest = {
    "requests.cpu"           = "8"
    "requests.memory"        = "16Gi"
    "requests.storage"       = "50Gi"
    "persistentvolumeclaims" = "5"
    "pods"                   = "25"
  }

  namespace_resourcequota_sandbox = {
    "requests.cpu"           = "8"
    "requests.memory"        = "16Gi"
    "limits.cpu"             = "16"
    "limits.memory"          = "32Gi"
    "requests.storage"       = "200Gi"
    "persistentvolumeclaims" = "10"
    "pods"                   = "20"
  }

  namespace_resourcequota_tenant = {
    "requests.cpu"           = "32"
    "requests.memory"        = "64Gi"
    "requests.storage"       = "250Gi"
    "persistentvolumeclaims" = "25"
    "pods"                   = "100"
  }

  namespace_resourcequota_gitlab_runner = {
    "requests.cpu"               = "12"
    "requests.memory"            = "20Gi"
    "requests.ephemeral-storage" = "96Gi"
    "limits.cpu"                 = "20"
    "limits.memory"              = "40Gi"
    "limits.ephemeral-storage"   = "256Gi"
    "pods"                       = "20"
  }
}

resource "kubectl_manifest" "kyverno_namespace_resourcequota" {
  depends_on = [
    helm_release.kyverno,
    kubectl_manifest.kyverno_namespace_resourcequota_rbac,
  ]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "GeneratingPolicy"
    metadata = {
      name = "namespace-resourcequota"
      annotations = {
        "policies.kyverno.io/title"       = "Namespace ResourceQuota"
        "policies.kyverno.io/category"    = "Resource Management"
        "policies.kyverno.io/subject"     = "Namespace,ResourceQuota"
        "policies.kyverno.io/description" = "Generate ResourceQuota profiles from namespace contract tier labels."
      }
    }
    spec = {
      evaluation = {
        synchronize = {
          enabled = true
        }
        generateExisting = {
          enabled = true
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["namespaces"]
          scope       = "Cluster"
        }]
      }
      matchConditions = [
        {
          name       = "resourcequota-tier-or-gitlab-runner"
          expression = "object.metadata.name == 'gitlab-runner' || (has(object.metadata.labels) && 'aether.shdr.ch/tier' in object.metadata.labels && object.metadata.labels['aether.shdr.ch/tier'] in ['guest', 'sandbox', 'tenant'])"
        },
      ]
      variables = [
        {
          name       = "targetNamespace"
          expression = "object.metadata.name"
        },
        {
          name       = "quotaHard"
          expression = <<-EOT
            object.metadata.name == "gitlab-runner" ?
              dyn(${jsonencode(local.namespace_resourcequota_gitlab_runner)}) :
            object.metadata.labels["aether.shdr.ch/tier"] == "sandbox" ?
              dyn(${jsonencode(local.namespace_resourcequota_sandbox)}) :
            object.metadata.labels["aether.shdr.ch/tier"] == "tenant" ?
              dyn(${jsonencode(local.namespace_resourcequota_tenant)}) :
              dyn(${jsonencode(local.namespace_resourcequota_guest)})
          EOT
        },
        {
          name       = "resourceQuota"
          expression = <<-EOT
            [
              {
                "apiVersion": dyn("v1"),
                "kind": dyn("ResourceQuota"),
                "metadata": dyn({
                  "name": "namespace-quota",
                  "namespace": string(variables.targetNamespace)
                }),
                "spec": dyn({
                  "hard": variables.quotaHard
                })
              }
            ]
          EOT
        },
      ]
      generate = [{
        expression = "generator.Apply(variables.targetNamespace, variables.resourceQuota)"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_priority_controller_template_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:priority-controller-template"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-admission-controller"  = "true"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
        "rbac.kyverno.io/aggregate-to-reports-controller"    = "true"
      }
    }
    rules = [
      {
        apiGroups = ["apps"]
        resources = ["deployments", "daemonsets", "statefulsets", "replicasets"]
        verbs     = ["get", "list", "watch", "patch", "update"]
      },
      {
        apiGroups = ["batch"]
        resources = ["cronjobs"]
        verbs     = ["get", "list", "watch", "patch", "update"]
      },
    ]
  })
}

resource "kubectl_manifest" "kyverno_namespace_priority_class_default" {
  depends_on = [
    kubectl_manifest.kyverno_priority_controller_template_rbac,
    kubernetes_priority_class_v1.aether_platform,
    kubernetes_priority_class_v1.aether_app,
    kubernetes_priority_class_v1.aether_batch,
    kubernetes_priority_class_v1.aether_sandbox,
  ]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "namespace-priority-class-default"
      annotations = {
        "policies.kyverno.io/title"       = "Namespace PriorityClass Default"
        "policies.kyverno.io/category"    = "Scheduling"
        "policies.kyverno.io/subject"     = "Deployment,DaemonSet,StatefulSet,CronJob"
        "policies.kyverno.io/description" = "Default controller Pod-template priorityClassName from the namespace contract tier. Existing Jobs are immutable, so they are handled by create-time admission only."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "aether.shdr.ch/tier"
            operator = "In"
            values   = ["platform"]
          }]
        }
        resourceRules = [
          {
            apiGroups   = ["apps"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["deployments", "daemonsets", "statefulsets", "replicasets"]
            scope       = "Namespaced"
          },
          {
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["cronjobs"]
            scope       = "Namespaced"
          },
        ]
      }
      matchConditions = [{
        name       = "missing-priority-class"
        expression = "object.kind == \"CronJob\" ? (!has(object.spec.jobTemplate.spec.template.spec.priorityClassName) || object.spec.jobTemplate.spec.template.spec.priorityClassName == \"\") : (!has(object.spec.template.spec.priorityClassName) || object.spec.template.spec.priorityClassName == \"\")"
      }]
      variables = [
        {
          name       = "priorityClass"
          expression = "\"${local.aether_priority_classes.platform}\""
        },
        {
          name       = "priorityClassPath"
          expression = "object.kind == \"CronJob\" ? \"/spec/jobTemplate/spec/template/spec/priorityClassName\" : \"/spec/template/spec/priorityClassName\""
        },
      ]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            [
              JSONPatch{op: "add", path: variables.priorityClassPath, value: variables.priorityClass}
            ]
          EOT
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_namespace_priority_class_default_tier" {
  for_each = {
    app = {
      name           = "namespace-priority-class-default-app"
      title          = "Namespace App PriorityClass Default"
      selector_op    = "In"
      selector_tiers = ["app"]
      priority_class = local.aether_priority_classes.app
    }
    batch = {
      name           = "namespace-priority-class-default-batch"
      title          = "Namespace Batch PriorityClass Default"
      selector_op    = "In"
      selector_tiers = ["agent"]
      priority_class = local.aether_priority_classes.batch
    }
    sandbox = {
      name           = "namespace-priority-class-default-sandbox"
      title          = "Namespace Sandbox PriorityClass Default"
      selector_op    = "NotIn"
      selector_tiers = ["platform", "app", "agent"]
      priority_class = local.aether_priority_classes.sandbox
    }
  }

  depends_on = [
    kubectl_manifest.kyverno_priority_controller_template_rbac,
    kubernetes_priority_class_v1.aether_app,
    kubernetes_priority_class_v1.aether_batch,
    kubernetes_priority_class_v1.aether_sandbox,
  ]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name = each.value.name
      annotations = {
        "policies.kyverno.io/title"       = each.value.title
        "policies.kyverno.io/category"    = "Scheduling"
        "policies.kyverno.io/subject"     = "Deployment,DaemonSet,StatefulSet,CronJob"
        "policies.kyverno.io/description" = "Default controller Pod-template priorityClassName from the namespace contract tier. Existing Jobs are immutable, so they are handled by create-time admission only."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "aether.shdr.ch/tier"
            operator = each.value.selector_op
            values   = each.value.selector_tiers
          }]
        }
        resourceRules = [
          {
            apiGroups   = ["apps"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["deployments", "daemonsets", "statefulsets", "replicasets"]
            scope       = "Namespaced"
          },
          {
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["cronjobs"]
            scope       = "Namespaced"
          },
        ]
      }
      matchConditions = [{
        name       = "missing-priority-class"
        expression = "object.kind == \"CronJob\" ? (!has(object.spec.jobTemplate.spec.template.spec.priorityClassName) || object.spec.jobTemplate.spec.template.spec.priorityClassName == \"\") : (!has(object.spec.template.spec.priorityClassName) || object.spec.template.spec.priorityClassName == \"\")"
      }]
      variables = [
        {
          name       = "priorityClass"
          expression = "\"${each.value.priority_class}\""
        },
        {
          name       = "priorityClassPath"
          expression = "object.kind == \"CronJob\" ? \"/spec/jobTemplate/spec/template/spec/priorityClassName\" : \"/spec/template/spec/priorityClassName\""
        },
      ]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            [
              JSONPatch{op: "add", path: variables.priorityClassPath, value: variables.priorityClass}
            ]
          EOT
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_namespace_priority_class_default_job" {
  depends_on = [
    helm_release.kyverno,
    kubernetes_priority_class_v1.aether_platform,
    kubernetes_priority_class_v1.aether_app,
    kubernetes_priority_class_v1.aether_batch,
    kubernetes_priority_class_v1.aether_sandbox,
  ]


  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name = "namespace-priority-class-default-job"
      annotations = {
        "policies.kyverno.io/title"       = "Namespace Job PriorityClass Default"
        "policies.kyverno.io/category"    = "Scheduling"
        "policies.kyverno.io/subject"     = "Job"
        "policies.kyverno.io/description" = "Default Job Pod-template priorityClassName from the namespace contract tier at create time only. Existing Jobs are immutable."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "aether.shdr.ch/tier"
            operator = "In"
            values   = ["platform"]
          }]
        }
        resourceRules = [{
          apiGroups   = ["batch"]
          apiVersions = ["v1"]
          operations  = ["CREATE"]
          resources   = ["jobs"]
          scope       = "Namespaced"
        }]
      }
      matchConditions = [{
        name       = "missing-priority-class"
        expression = "!has(object.spec.template.spec.priorityClassName) || object.spec.template.spec.priorityClassName == \"\""
      }]
      variables = [{
        name       = "priorityClass"
        expression = "\"${local.aether_priority_classes.platform}\""
      }]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            [
              JSONPatch{op: "add", path: "/spec/template/spec/priorityClassName", value: variables.priorityClass}
            ]
          EOT
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_namespace_priority_class_default_job_tier" {
  for_each = {
    app = {
      name           = "namespace-priority-class-default-job-app"
      title          = "Namespace App Job PriorityClass Default"
      selector_op    = "In"
      selector_tiers = ["app"]
      priority_class = local.aether_priority_classes.app
    }
    batch = {
      name           = "namespace-priority-class-default-job-batch"
      title          = "Namespace Batch Job PriorityClass Default"
      selector_op    = "In"
      selector_tiers = ["agent"]
      priority_class = local.aether_priority_classes.batch
    }
    sandbox = {
      name           = "namespace-priority-class-default-job-sandbox"
      title          = "Namespace Sandbox Job PriorityClass Default"
      selector_op    = "NotIn"
      selector_tiers = ["platform", "app", "agent"]
      priority_class = local.aether_priority_classes.sandbox
    }
  }

  depends_on = [
    helm_release.kyverno,
    kubernetes_priority_class_v1.aether_app,
    kubernetes_priority_class_v1.aether_batch,
    kubernetes_priority_class_v1.aether_sandbox,
  ]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "MutatingPolicy"
    metadata = {
      name = each.value.name
      annotations = {
        "policies.kyverno.io/title"       = each.value.title
        "policies.kyverno.io/category"    = "Scheduling"
        "policies.kyverno.io/subject"     = "Job"
        "policies.kyverno.io/description" = "Default Job Pod-template priorityClassName from the namespace contract tier at create time only. Existing Jobs are immutable."
      }
    }
    spec = {
      failurePolicy      = "Ignore"
      reinvocationPolicy = "IfNeeded"
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "aether.shdr.ch/tier"
            operator = each.value.selector_op
            values   = each.value.selector_tiers
          }]
        }
        resourceRules = [{
          apiGroups   = ["batch"]
          apiVersions = ["v1"]
          operations  = ["CREATE"]
          resources   = ["jobs"]
          scope       = "Namespaced"
        }]
      }
      matchConditions = [{
        name       = "missing-priority-class"
        expression = "!has(object.spec.template.spec.priorityClassName) || object.spec.template.spec.priorityClassName == \"\""
      }]
      variables = [{
        name       = "priorityClass"
        expression = "\"${each.value.priority_class}\""
      }]
      mutations = [{
        patchType = "JSONPatch"
        jsonPatch = {
          expression = <<-EOT
            [
              JSONPatch{op: "add", path: "/spec/template/spec/priorityClassName", value: variables.priorityClass}
            ]
          EOT
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_namespace_priority_class_allowed" {
  depends_on = [
    helm_release.kyverno,
    kubernetes_priority_class_v1.aether_platform,
    kubernetes_priority_class_v1.aether_app,
    kubernetes_priority_class_v1.aether_batch,
    kubernetes_priority_class_v1.aether_sandbox,
  ]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "namespace-priority-class-allowed"
      annotations = {
        "policies.kyverno.io/title"       = "Namespace PriorityClass Allowed"
        "policies.kyverno.io/category"    = "Scheduling"
        "policies.kyverno.io/subject"     = "Pod"
        "policies.kyverno.io/description" = "Reject Pods that request a priorityClassName above the namespace contract tier."
      }
    }
    spec = {
      failurePolicy     = "Fail"
      validationActions = ["Deny"]
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = false
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["pods"]
          scope       = "Namespaced"
        }]
      }
      variables = [
        {
          name       = "tier"
          expression = "namespaceObject != null && has(namespaceObject.metadata.labels) && \"aether.shdr.ch/tier\" in namespaceObject.metadata.labels ? namespaceObject.metadata.labels[\"aether.shdr.ch/tier\"] : \"unclassified\""
        },
        {
          name       = "priorityClass"
          expression = "has(object.spec.priorityClassName) ? object.spec.priorityClassName : \"\""
        },
        {
          name       = "allowedPriorityClasses"
          expression = "variables.tier == \"platform\" ? ${jsonencode(local.aether_allowed_priority_classes.platform)} : variables.tier == \"app\" ? ${jsonencode(local.aether_allowed_priority_classes.app)} : variables.tier == \"agent\" ? ${jsonencode(local.aether_allowed_priority_classes.batch)} : ${jsonencode(local.aether_allowed_priority_classes.sandbox)}"
        },
      ]
      validations = [{
        expression = "variables.priorityClass == \"\" || variables.priorityClass in variables.allowedPriorityClasses"
        message    = "Pod priorityClassName must be at or below the namespace contract tier."
        reason     = "Forbidden"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_httproute_hostname_contract_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:httproute-hostname-contract"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-admission-controller"  = "true"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
        "rbac.kyverno.io/aggregate-to-reports-controller"    = "true"
      }
    }
    rules = [{
      apiGroups = ["gateway.networking.k8s.io"]
      resources = ["httproutes"]
      verbs     = ["get", "list", "watch"]
    }]
  })
}

resource "kubectl_manifest" "kyverno_httproute_hostname_contract" {
  depends_on = [helm_release.kyverno, kubectl_manifest.kyverno_httproute_hostname_contract_rbac]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "httproute-hostname-contract"
      annotations = {
        "policies.kyverno.io/title"       = "HTTPRoute Hostname Contract"
        "policies.kyverno.io/category"    = "Networking"
        "policies.kyverno.io/subject"     = "HTTPRoute"
        "policies.kyverno.io/description" = "Deny HTTPRoutes whose hostnames are not declared on their namespace contract."
      }
    }
    spec = {
      failurePolicy     = "Fail"
      validationActions = ["Deny"]
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = true
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["gateway.networking.k8s.io"]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["httproutes"]
          scope       = "Namespaced"
        }]
      }
      variables = [{
        name       = "allowedHostnames"
        expression = "namespaceObject != null && has(namespaceObject.metadata.annotations) && \"aether.shdr.ch/hostnames\" in namespaceObject.metadata.annotations && namespaceObject.metadata.annotations[\"aether.shdr.ch/hostnames\"] != \"\" ? namespaceObject.metadata.annotations[\"aether.shdr.ch/hostnames\"].split(\",\") : []"
      }]
      validations = [{
        expression = "!has(object.spec.hostnames) || object.spec.hostnames.all(hostname, hostname in variables.allowedHostnames)"
        message    = "HTTPRoute spec.hostnames must be declared in the namespace aether.shdr.ch/hostnames annotation."
        reason     = "Forbidden"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_cloudflared_tunnel_namespace" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "cloudflared-tunnel-namespace"
      annotations = {
        "policies.kyverno.io/title"       = "Cloudflared Tunnel Namespace"
        "policies.kyverno.io/category"    = "Networking"
        "policies.kyverno.io/subject"     = "Pod"
        "policies.kyverno.io/description" = "Permit cloudflared Pods only in namespaces whose exposure contract is tunnel."
      }
    }
    spec = {
      failurePolicy     = "Fail"
      validationActions = ["Deny"]
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = true
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["pods"]
          scope       = "Namespaced"
        }]
      }
      variables = [
        {
          name       = "namespaceExposure"
          expression = "namespaceObject != null && has(namespaceObject.metadata.labels) && \"aether.shdr.ch/exposure\" in namespaceObject.metadata.labels ? namespaceObject.metadata.labels[\"aether.shdr.ch/exposure\"] : \"none\""
        },
        {
          name       = "images"
          expression = "object.spec.containers.map(container, container.image) + (has(object.spec.initContainers) ? object.spec.initContainers.map(container, container.image) : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(container, container.image) : [])"
        },
      ]
      validations = [{
        expression = "variables.namespaceExposure == \"tunnel\" || !variables.images.exists(image, image.matches(\"(^|/)cloudflare/cloudflared([:@]|$)\"))"
        message    = "cloudflare/cloudflared images are allowed only in namespaces labeled aether.shdr.ch/exposure=tunnel."
        reason     = "Forbidden"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_critical_namespace_image_tags" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "critical-namespace-image-tags"
      annotations = {
        "policies.kyverno.io/title"       = "Critical Namespace Image Tags"
        "policies.kyverno.io/category"    = "Supply Chain"
        "policies.kyverno.io/subject"     = "Pod"
        "policies.kyverno.io/description" = "Audit floating image tags in backup-critical namespaces before enforcing rollback-safe image references."
      }
    }
    spec = {
      failurePolicy     = "Fail"
      validationActions = ["Audit"]
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = true
        }
      }
      matchConstraints = {
        namespaceSelector = {
          matchExpressions = [{
            key      = "aether.shdr.ch/backup"
            operator = "In"
            values   = ["critical"]
          }]
        }
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["pods"]
          scope       = "Namespaced"
        }]
      }
      variables = [{
        name       = "images"
        expression = "object.spec.containers.map(container, container.image) + (has(object.spec.initContainers) ? object.spec.initContainers.map(container, container.image) : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(container, container.image) : [])"
      }]
      validations = [{
        expression = "variables.images.all(image, image.contains(\"@sha256:\") || (image.matches(\"^[^:]+(:[0-9]+)?/.*:[^:/@]+$\") && !image.matches(\".*:(latest|main|master|dev|develop|nightly|edge|canary|snapshot)$\")) || (image.matches(\"^[^/:]+:[^:/@]+$\") && !image.matches(\".*:(latest|main|master|dev|develop|nightly|edge|canary|snapshot)$\")))"
        message    = "Pods in backup-critical namespaces should use a digest or an explicit non-floating tag, not latest/main/dev/nightly-style tags or untagged images."
        reason     = "Forbidden"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_cnpg_backup_contract" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "cnpg-backup-contract"
      annotations = {
        "policies.kyverno.io/title"       = "CNPG Backup Contract"
        "policies.kyverno.io/category"    = "Database"
        "policies.kyverno.io/subject"     = "Cluster"
        "policies.kyverno.io/description" = "Reject CNPG clusters in backed-up namespaces unless they declare a Barman backup target."
      }
    }
    spec = {
      failurePolicy     = "Fail"
      validationActions = ["Deny"]
      evaluation = {
        admission = {
          enabled = true
        }
        background = {
          enabled = true
        }
      }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["postgresql.cnpg.io"]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["clusters"]
          scope       = "Namespaced"
        }]
      }
      variables = [{
        name       = "namespaceBackup"
        expression = "namespaceObject != null && has(namespaceObject.metadata.labels) && \"aether.shdr.ch/backup\" in namespaceObject.metadata.labels ? namespaceObject.metadata.labels[\"aether.shdr.ch/backup\"] : \"none\""
      }]
      validations = [{
        expression = "variables.namespaceBackup == \"none\" || (has(object.spec.backup) && has(object.spec.backup.barmanObjectStore)) || (has(object.spec.plugins) && object.spec.plugins.exists(plugin, plugin.name == \"${local.cnpg_barman_plugin_name}\" && has(plugin.parameters) && \"barmanObjectName\" in plugin.parameters && plugin.parameters[\"barmanObjectName\"] != \"\"))"
        message    = "CNPG clusters in namespaces with aether.shdr.ch/backup != none must declare spec.backup.barmanObjectStore or the Barman Cloud plugin barmanObjectName parameter."
        reason     = "Forbidden"
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_legacy_postgres_sts_retirement_rbac" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "kyverno:legacy-postgres-sts-retirement"
      labels = {
        "app.kubernetes.io/component"                        = "rbac"
        "app.kubernetes.io/instance"                         = helm_release.kyverno.name
        "app.kubernetes.io/part-of"                          = "kyverno"
        "rbac.kyverno.io/aggregate-to-admission-controller"  = "true"
        "rbac.kyverno.io/aggregate-to-background-controller" = "true"
        "rbac.kyverno.io/aggregate-to-reports-controller"    = "true"
      }
    }
    rules = [{
      apiGroups = ["postgresql.cnpg.io"]
      resources = ["clusters"]
      verbs     = ["get", "list", "watch"]
    }]
  })
}

resource "kubectl_manifest" "kyverno_legacy_postgres_sts_retirement" {
  depends_on = [
    helm_release.kyverno,
    kubectl_manifest.kyverno_legacy_postgres_sts_retirement_rbac,
  ]

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "legacy-postgres-sts-retirement"
      annotations = {
        "policies.kyverno.io/title"       = "Legacy PostgreSQL StatefulSet Retirement"
        "policies.kyverno.io/category"    = "Database"
        "policies.kyverno.io/subject"     = "StatefulSet"
        "policies.kyverno.io/description" = "Audit legacy hand-managed PostgreSQL StatefulSets that remain in namespaces after a CNPG Cluster exists."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "retire-legacy-postgres-sts-after-cnpg-cutover"
        match = {
          any = [{
            resources = {
              kinds = ["StatefulSet"]
            }
          }]
        }
        exclude = {
          any = [{
            resources = {
              namespaces = ["kube-system", "kube-public", "kube-node-lease", "cnpg-system"]
            }
          }]
        }
        context = [{
          name = "cnpgClusters"
          apiCall = {
            urlPath  = "/apis/postgresql.cnpg.io/v1/namespaces/{{ request.object.metadata.namespace }}/clusters"
            jmesPath = "items[].metadata.name"
          }
        }]
        preconditions = {
          all = [
            {
              key      = "{{ contains(request.object.metadata.name, 'postgres') }}"
              operator = "Equals"
              value    = true
            },
            {
              key      = "{{ length(cnpgClusters) }}"
              operator = "GreaterThan"
              value    = 0
            }
          ]
        }
        validate = {
          message = "Legacy PostgreSQL StatefulSet remains after CNPG cutover; delete it within the retirement window once restore/backups are verified."
          deny = {
            conditions = {
              any = [{
                key      = "{{ request.operation || 'BACKGROUND' }}"
                operator = "AnyIn"
                value    = ["CREATE", "UPDATE", "BACKGROUND"]
              }]
            }
          }
        }
      }]
    }
  })
}
