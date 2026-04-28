# =============================================================================
# aether-k8s-arch-labeler
# =============================================================================
# Mutating admission webhook that automatically labels small Pods as ARM-safe
# when all container images publish linux/arm64 manifests. Kyverno remains the
# enforcement point for binding Pods onto Raspberry Pi workers.

locals {
  aether_k8s_arch_labeler_namespace = "aether-k8s-arch-labeler"
  aether_k8s_arch_labeler_name      = "aether-k8s-arch-labeler"
  aether_k8s_arch_labeler_image     = "registry.gitlab.home.shdr.ch/so/aether/aether-k8s-arch-labeler:944ccf25"
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_namespace" {
  depends_on = [helm_release.cilium]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.aether_k8s_arch_labeler_namespace
      labels = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
    }
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_service_account" {
  depends_on = [kubectl_manifest.aether_k8s_arch_labeler_namespace]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = local.aether_k8s_arch_labeler_name
      namespace = local.aether_k8s_arch_labeler_namespace
      labels = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
    }
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_cluster_role" {
  depends_on = [kubectl_manifest.aether_k8s_arch_labeler_service_account]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = local.aether_k8s_arch_labeler_name
      labels = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
    }
    rules = [{
      apiGroups = [""]
      resources = ["pods"]
      verbs     = ["get", "list", "patch"]
    }]
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_cluster_role_binding" {
  depends_on = [
    kubectl_manifest.aether_k8s_arch_labeler_cluster_role,
    kubectl_manifest.aether_k8s_arch_labeler_service_account,
  ]

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = local.aether_k8s_arch_labeler_name
      labels = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = local.aether_k8s_arch_labeler_name
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = local.aether_k8s_arch_labeler_name
      namespace = local.aether_k8s_arch_labeler_namespace
    }]
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_issuer" {
  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.aether_k8s_arch_labeler_namespace,
  ]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "${local.aether_k8s_arch_labeler_name}-selfsigned"
      namespace = local.aether_k8s_arch_labeler_namespace
    }
    spec = {
      selfSigned = {}
    }
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_certificate" {
  depends_on = [kubectl_manifest.aether_k8s_arch_labeler_issuer]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "${local.aether_k8s_arch_labeler_name}-tls"
      namespace = local.aether_k8s_arch_labeler_namespace
    }
    spec = {
      secretName  = "${local.aether_k8s_arch_labeler_name}-tls"
      duration    = "8760h"
      renewBefore = "720h"
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      dnsNames = [
        "${local.aether_k8s_arch_labeler_name}.${local.aether_k8s_arch_labeler_namespace}.svc",
        "${local.aether_k8s_arch_labeler_name}.${local.aether_k8s_arch_labeler_namespace}.svc.cluster.local",
      ]
      issuerRef = {
        name = "${local.aether_k8s_arch_labeler_name}-selfsigned"
        kind = "Issuer"
      }
    }
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_service" {
  depends_on = [kubectl_manifest.aether_k8s_arch_labeler_namespace]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = local.aether_k8s_arch_labeler_name
      namespace = local.aether_k8s_arch_labeler_namespace
      labels = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
    }
    spec = {
      selector = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
      ports = [{
        name       = "webhook"
        port       = 443
        targetPort = 8443
        protocol   = "TCP"
      }]
    }
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_deployment" {
  depends_on = [
    kubectl_manifest.aether_k8s_arch_labeler_certificate,
    kubectl_manifest.aether_k8s_arch_labeler_cluster_role_binding,
    kubectl_manifest.aether_k8s_arch_labeler_service_account,
    kubectl_manifest.kyverno_arm_pool_guardrails,
  ]

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.aether_k8s_arch_labeler_name
      namespace = local.aether_k8s_arch_labeler_namespace
      labels = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
    }
    spec = {
      replicas = 2
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
        }
      }
      template = {
        metadata = {
          labels = {
            "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
            "aether.sh/arm-ok"       = "true"
          }
        }
        spec = {
          serviceAccountName           = local.aether_k8s_arch_labeler_name
          automountServiceAccountToken = true
          securityContext = {
            runAsNonRoot = true
            runAsUser    = 65532
            runAsGroup   = 65532
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }
          containers = [{
            name            = "webhook"
            image           = local.aether_k8s_arch_labeler_image
            imagePullPolicy = "Always"
            env = [
              { name = "LISTEN_ADDR", value = ":8443" },
              { name = "TLS_CERT_FILE", value = "/tls/tls.crt" },
              { name = "TLS_KEY_FILE", value = "/tls/tls.key" },
              { name = "TARGET_OS", value = "linux" },
              { name = "TARGET_ARCH", value = "arm64" },
              { name = "ARM_OK_LABEL", value = "aether.sh/arm-ok" },
              { name = "ARM_OK_VALUE", value = "true" },
              { name = "PREFER_ARM_POOL", value = "true" },
              { name = "ARM_POOL_LABEL", value = "aether.sh/node-pool" },
              { name = "ARM_POOL_VALUE", value = "arm" },
              { name = "ARM_POOL_PREFERENCE_WEIGHT", value = "35" },
              { name = "MAX_MEMORY_REQUEST", value = "512Mi" },
              { name = "REGISTRY_TIMEOUT", value = "10s" },
              { name = "CACHE_TTL", value = "24h" },
              { name = "BACKFILL_EXISTING_PODS", value = "true" },
              { name = "BACKFILL_INTERVAL", value = "1h" },
              { name = "LOG_LEVEL", value = "info" },
            ]
            envFrom = [{
              secretRef = {
                name     = "${local.aether_k8s_arch_labeler_name}-gitlab"
                optional = true
              }
            }]
            ports = [{
              name          = "webhook"
              containerPort = 8443
              protocol      = "TCP"
            }]
            readinessProbe = {
              httpGet = {
                path   = "/healthz"
                port   = "webhook"
                scheme = "HTTPS"
              }
              initialDelaySeconds = 2
              periodSeconds       = 5
            }
            livenessProbe = {
              httpGet = {
                path   = "/healthz"
                port   = "webhook"
                scheme = "HTTPS"
              }
              initialDelaySeconds = 5
              periodSeconds       = 10
            }
            resources = {
              requests = {
                cpu    = "25m"
                memory = "64Mi"
              }
              limits = {
                cpu    = "200m"
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
            volumeMounts = [{
              name      = "tls"
              mountPath = "/tls"
              readOnly  = true
            }]
          }]
          volumes = [{
            name = "tls"
            secret = {
              secretName = "${local.aether_k8s_arch_labeler_name}-tls"
            }
          }]
          topologySpreadConstraints = [{
            maxSkew           = 1
            topologyKey       = "kubernetes.io/hostname"
            whenUnsatisfiable = "ScheduleAnyway"
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
              }
            }
          }]
        }
      }
    }
  })
}

resource "kubectl_manifest" "aether_k8s_arch_labeler_webhook" {
  depends_on = [
    kubectl_manifest.aether_k8s_arch_labeler_service,
    kubectl_manifest.aether_k8s_arch_labeler_deployment,
  ]

  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "MutatingWebhookConfiguration"
    metadata = {
      name = local.aether_k8s_arch_labeler_name
      annotations = {
        "cert-manager.io/inject-ca-from" = "${local.aether_k8s_arch_labeler_namespace}/${local.aether_k8s_arch_labeler_name}-tls"
      }
      labels = {
        "app.kubernetes.io/name" = local.aether_k8s_arch_labeler_name
      }
    }
    webhooks = [{
      name                    = "arch-labeler.aether.sh"
      admissionReviewVersions = ["v1"]
      sideEffects             = "None"
      failurePolicy           = "Ignore"
      timeoutSeconds          = 5
      reinvocationPolicy      = "Never"
      matchPolicy             = "Equivalent"
      rules = [{
        operations  = ["CREATE"]
        apiGroups   = [""]
        apiVersions = ["v1"]
        resources   = ["pods"]
        scope       = "Namespaced"
      }]
      namespaceSelector = {
        matchExpressions = [
          {
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            values = [
              "kube-system",
              "kube-public",
              "kube-node-lease",
              "kyverno",
              "istio-system",
              local.aether_k8s_arch_labeler_namespace,
            ]
          },
          {
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            values   = ["system"]
          },
        ]
      }
      objectSelector = {
        matchExpressions = [{
          key      = "aether.sh/arm-ok"
          operator = "DoesNotExist"
        }]
      }
      clientConfig = {
        service = {
          name      = local.aether_k8s_arch_labeler_name
          namespace = local.aether_k8s_arch_labeler_namespace
          path      = "/mutate"
          port      = 443
        }
      }
    }]
  })
}
