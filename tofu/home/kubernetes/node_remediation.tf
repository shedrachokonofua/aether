# =============================================================================
# Node remediation
# =============================================================================
# Installs Medik8s NodeHealthCheck and wires it to the Aether node remediator.
# The remediator controller/template itself is deployed from the sibling
# aether-k8s-node-remediator repo.

locals {
  node_healthcheck_operator_version   = "v0.11.0"
  node_healthcheck_operator_namespace = "node-healthcheck-operator-system"
  node_healthcheck_operator_name      = "node-healthcheck-operator"
  node_healthcheck_controller_name    = "node-healthcheck-controller-manager"
  node_healthcheck_crd_url            = "https://raw.githubusercontent.com/medik8s/node-healthcheck-operator/${local.node_healthcheck_operator_version}/config/crd/bases/remediation.medik8s.io_nodehealthchecks.yaml"

  node_healthcheck_labels = {
    "app.kubernetes.io/name" = local.node_healthcheck_operator_name
  }

  node_healthcheck_controller_labels = merge(local.node_healthcheck_labels, {
    "app.kubernetes.io/component" = "controller-manager"
  })

  node_healthcheck_remediation_template = {
    apiVersion = "node-remediation.aether.sh/v1alpha1"
    kind       = "AetherNodeRemediationTemplate"
    name       = "out-of-service-taint"
    namespace  = "aether-k8s-node-remediator"
  }
}

data "http" "node_healthcheck_crd" {
  url = local.node_healthcheck_crd_url
}

resource "kubectl_manifest" "node_healthcheck_operator_namespace" {
  depends_on = [helm_release.cilium]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = local.node_healthcheck_operator_namespace
      labels = local.node_healthcheck_controller_labels
    }
  })
}

resource "kubectl_manifest" "node_healthcheck_crd" {
  depends_on = [helm_release.cilium]

  yaml_body = data.http.node_healthcheck_crd.response_body
}

resource "kubectl_manifest" "node_healthcheck_service_account" {
  depends_on = [kubectl_manifest.node_healthcheck_operator_namespace]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = local.node_healthcheck_controller_name
      namespace = local.node_healthcheck_operator_namespace
      labels    = local.node_healthcheck_labels
    }
  })
}

resource "kubectl_manifest" "node_healthcheck_leader_election_role" {
  depends_on = [kubectl_manifest.node_healthcheck_operator_namespace]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "node-healthcheck-leader-election-role"
      namespace = local.node_healthcheck_operator_namespace
      labels    = local.node_healthcheck_labels
    }
    rules = [
      {
        apiGroups = [""]
        resources = ["configmaps"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      },
      {
        apiGroups = ["coordination.k8s.io"]
        resources = ["leases"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      },
      {
        apiGroups = [""]
        resources = ["events"]
        verbs     = ["create", "patch"]
      },
    ]
  })
}

resource "kubectl_manifest" "node_healthcheck_manager_role" {
  depends_on = [kubectl_manifest.node_healthcheck_crd]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "node-healthcheck-manager-role"
      labels = merge(local.node_healthcheck_labels, {
        "rbac.ext-remediation/aggregate-to-ext-remediation" = "true"
      })
    }
    rules = [
      {
        apiGroups = [""]
        resources = ["namespaces"]
        verbs     = ["create", "get"]
      },
      {
        apiGroups = [""]
        resources = ["nodes", "pods"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = ["apps"]
        resources = ["deployments"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = ["config.openshift.io"]
        resources = ["clusterversions", "featuregates", "infrastructures"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = ["console.openshift.io"]
        resources = ["consoleplugins"]
        verbs     = ["create", "delete", "get", "list", "patch", "update", "watch"]
      },
      {
        apiGroups = ["coordination.k8s.io"]
        resources = ["leases"]
        verbs     = ["create", "delete", "get", "list", "patch", "update", "watch"]
      },
      {
        apiGroups = ["machine.openshift.io"]
        resources = ["machinehealthchecks"]
        verbs     = ["get", "list", "patch", "update", "watch"]
      },
      {
        apiGroups = ["machine.openshift.io"]
        resources = ["machinehealthchecks/status"]
        verbs     = ["get", "patch", "update"]
      },
      {
        apiGroups = ["machine.openshift.io"]
        resources = ["machines"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = ["policy"]
        resources = ["poddisruptionbudgets"]
        verbs     = ["get", "list", "watch"]
      },
      {
        apiGroups = ["rbac.authorization.k8s.io"]
        resources = ["clusterrolebindings", "clusterroles"]
        verbs     = ["*"]
      },
      {
        apiGroups = ["remediation.medik8s.io"]
        resources = ["nodehealthchecks"]
        verbs     = ["create", "delete", "get", "list", "patch", "update", "watch"]
      },
      {
        apiGroups = ["remediation.medik8s.io"]
        resources = ["nodehealthchecks/finalizers"]
        verbs     = ["update"]
      },
      {
        apiGroups = ["remediation.medik8s.io"]
        resources = ["nodehealthchecks/status"]
        verbs     = ["get", "patch", "update"]
      },
      {
        apiGroups = ["node-remediation.aether.sh"]
        resources = ["aethernoderemediationtemplates", "aethernoderemediations"]
        verbs     = ["create", "delete", "get", "list", "patch", "update", "watch"]
      },
      {
        apiGroups = ["node-remediation.aether.sh"]
        resources = ["aethernoderemediations/status"]
        verbs     = ["get", "patch", "update"]
      },
    ]
  })
}

resource "kubectl_manifest" "node_healthcheck_metrics_reader_role" {
  depends_on = [kubectl_manifest.node_healthcheck_operator_namespace]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name   = "node-healthcheck-metrics-reader"
      labels = local.node_healthcheck_labels
    }
    rules = [{
      nonResourceURLs = ["/metrics"]
      verbs           = ["get"]
    }]
  })
}

resource "kubectl_manifest" "node_healthcheck_proxy_role" {
  depends_on = [kubectl_manifest.node_healthcheck_operator_namespace]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name   = "node-healthcheck-proxy-role"
      labels = local.node_healthcheck_labels
    }
    rules = [
      {
        apiGroups = ["authentication.k8s.io"]
        resources = ["tokenreviews"]
        verbs     = ["create"]
      },
      {
        apiGroups = ["authorization.k8s.io"]
        resources = ["subjectaccessreviews"]
        verbs     = ["create"]
      },
    ]
  })
}

resource "kubectl_manifest" "node_healthcheck_leader_election_rolebinding" {
  depends_on = [
    kubectl_manifest.node_healthcheck_leader_election_role,
    kubectl_manifest.node_healthcheck_service_account,
  ]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "node-healthcheck-leader-election-rolebinding"
      namespace = local.node_healthcheck_operator_namespace
      labels    = local.node_healthcheck_labels
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "node-healthcheck-leader-election-role"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = local.node_healthcheck_controller_name
      namespace = local.node_healthcheck_operator_namespace
    }]
  })
}

resource "kubectl_manifest" "node_healthcheck_manager_rolebinding" {
  depends_on = [
    kubectl_manifest.node_healthcheck_manager_role,
    kubectl_manifest.node_healthcheck_service_account,
  ]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name   = "node-healthcheck-manager-rolebinding"
      labels = local.node_healthcheck_labels
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "node-healthcheck-manager-role"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = local.node_healthcheck_controller_name
      namespace = local.node_healthcheck_operator_namespace
    }]
  })
}

resource "kubectl_manifest" "node_healthcheck_proxy_rolebinding" {
  depends_on = [
    kubectl_manifest.node_healthcheck_proxy_role,
    kubectl_manifest.node_healthcheck_service_account,
  ]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name   = "node-healthcheck-proxy-rolebinding"
      labels = local.node_healthcheck_labels
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "node-healthcheck-proxy-role"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = local.node_healthcheck_controller_name
      namespace = local.node_healthcheck_operator_namespace
    }]
  })
}

resource "kubectl_manifest" "node_healthcheck_metrics_service" {
  depends_on = [kubectl_manifest.node_healthcheck_operator_namespace]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "${local.node_healthcheck_controller_name}-metrics-service"
      namespace = local.node_healthcheck_operator_namespace
      labels    = local.node_healthcheck_controller_labels
    }
    spec = {
      ports = [{
        name       = "https"
        port       = 8443
        targetPort = "https"
      }]
      selector = local.node_healthcheck_controller_labels
    }
  })
}

resource "kubectl_manifest" "node_healthcheck_operator_deployment" {
  depends_on = [
    kubectl_manifest.node_healthcheck_manager_rolebinding,
    kubectl_manifest.node_healthcheck_proxy_rolebinding,
    kubectl_manifest.node_healthcheck_leader_election_rolebinding,
    kubectl_manifest.node_healthcheck_metrics_service,
  ]

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.node_healthcheck_controller_name
      namespace = local.node_healthcheck_operator_namespace
      labels    = local.node_healthcheck_controller_labels
    }
    spec = {
      replicas = 2
      selector = {
        matchLabels = local.node_healthcheck_controller_labels
      }
      strategy = {
        type = "RollingUpdate"
        rollingUpdate = {
          maxSurge       = 0
          maxUnavailable = 1
        }
      }
      template = {
        metadata = {
          annotations = {
            "kubectl.kubernetes.io/default-container" = "manager"
          }
          labels = local.node_healthcheck_controller_labels
        }
        spec = {
          serviceAccountName = local.node_healthcheck_controller_name
          priorityClassName  = "system-cluster-critical"
          nodeSelector = {
            "kubernetes.io/arch" = "amd64"
          }
          securityContext = {
            runAsNonRoot = true
            runAsUser    = 65532
            runAsGroup   = 65532
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }
          affinity = {
            nodeAffinity = {
              preferredDuringSchedulingIgnoredDuringExecution = [
                {
                  weight = 3
                  preference = {
                    matchExpressions = [{
                      key      = "node-role.kubernetes.io/infra"
                      operator = "Exists"
                    }]
                  }
                },
                {
                  weight = 1
                  preference = {
                    matchExpressions = [{
                      key      = "node-role.kubernetes.io/master"
                      operator = "Exists"
                    }]
                  }
                },
                {
                  weight = 1
                  preference = {
                    matchExpressions = [{
                      key      = "node-role.kubernetes.io/control-plane"
                      operator = "Exists"
                    }]
                  }
                },
              ]
            }
          }
          containers = [
            {
              name  = "kube-rbac-proxy"
              image = "quay.io/brancz/kube-rbac-proxy:v0.15.0"
              args = [
                "--secure-listen-address=0.0.0.0:8443",
                "--http2-disable",
                "--upstream=http://127.0.0.1:8080/",
                "--logtostderr=true",
                "--v=0",
              ]
              ports = [{
                name          = "https"
                containerPort = 8443
              }]
              resources = {
                requests = {
                  cpu    = "5m"
                  memory = "64Mi"
                }
                limits = {
                  cpu    = "500m"
                  memory = "128Mi"
                }
              }
              securityContext = {
                allowPrivilegeEscalation = false
                readOnlyRootFilesystem   = true
                capabilities = {
                  drop = ["ALL"]
                }
              }
            },
            {
              name    = "manager"
              image   = "quay.io/medik8s/node-healthcheck-operator:${local.node_healthcheck_operator_version}"
              command = ["/manager"]
              args = [
                "--health-probe-bind-address=:8081",
                "--metrics-bind-address=127.0.0.1:8080",
                "--leader-elect",
              ]
              env = [{
                name = "DEPLOYMENT_NAMESPACE"
                valueFrom = {
                  fieldRef = {
                    fieldPath = "metadata.namespace"
                  }
                }
              }]
              livenessProbe = {
                httpGet = {
                  path = "/healthz"
                  port = 8081
                }
                initialDelaySeconds = 15
                periodSeconds       = 20
              }
              readinessProbe = {
                httpGet = {
                  path = "/readyz"
                  port = 8081
                }
                initialDelaySeconds = 5
                periodSeconds       = 10
              }
              resources = {
                requests = {
                  cpu    = "100m"
                  memory = "20Mi"
                }
              }
              securityContext = {
                allowPrivilegeEscalation = false
                readOnlyRootFilesystem   = true
                capabilities = {
                  drop = ["ALL"]
                }
              }
            },
          ]
          tolerations = [
            {
              key      = "node-role.kubernetes.io/master"
              operator = "Exists"
              effect   = "NoSchedule"
            },
            {
              key      = "node-role.kubernetes.io/control-plane"
              operator = "Exists"
              effect   = "NoSchedule"
            },
            {
              key      = "node-role.kubernetes.io/infra"
              operator = "Exists"
              effect   = "NoSchedule"
            },
            {
              key      = "node-role.kubernetes.io/infra"
              operator = "Exists"
              effect   = "NoExecute"
            },
          ]
          topologySpreadConstraints = [{
            maxSkew           = 1
            topologyKey       = "kubernetes.io/hostname"
            whenUnsatisfiable = "DoNotSchedule"
            labelSelector = {
              matchLabels = local.node_healthcheck_controller_labels
            }
          }]
          terminationGracePeriodSeconds = 10
        }
      }
    }
  })
}

resource "kubectl_manifest" "aether_worker_node_healthcheck" {
  depends_on = [kubectl_manifest.node_healthcheck_operator_deployment]

  yaml_body = yamlencode({
    apiVersion = "remediation.medik8s.io/v1alpha1"
    kind       = "NodeHealthCheck"
    metadata = {
      name = "aether-worker-node-healthcheck"
    }
    spec = {
      selector = {
        matchExpressions = [
          {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "DoesNotExist"
          },
          {
            key      = "node-role.kubernetes.io/master"
            operator = "DoesNotExist"
          },
        ]
      }
      remediationTemplate   = local.node_healthcheck_remediation_template
      minHealthy            = "80%"
      stormCooldownDuration = "10m"
      unhealthyConditions = [
        {
          type     = "Ready"
          status   = "False"
          duration = "300s"
        },
        {
          type     = "Ready"
          status   = "Unknown"
          duration = "300s"
        },
      ]
    }
  })
}

resource "kubectl_manifest" "aether_control_plane_node_healthcheck" {
  depends_on = [kubectl_manifest.node_healthcheck_operator_deployment]

  yaml_body = yamlencode({
    apiVersion = "remediation.medik8s.io/v1alpha1"
    kind       = "NodeHealthCheck"
    metadata = {
      name = "aether-control-plane-node-healthcheck"
    }
    spec = {
      selector = {
        matchExpressions = [{
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
        }]
      }
      remediationTemplate   = local.node_healthcheck_remediation_template
      minHealthy            = "2"
      stormCooldownDuration = "10m"
      unhealthyConditions = [
        {
          type     = "Ready"
          status   = "False"
          duration = "600s"
        },
        {
          type     = "Ready"
          status   = "Unknown"
          duration = "600s"
        },
      ]
    }
  })
}
