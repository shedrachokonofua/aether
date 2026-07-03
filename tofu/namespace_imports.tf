# =============================================================================
# Namespace root imports
# =============================================================================
# Import blocks are only valid in the root module. Moved blocks for namespaces
# already managed by tofu stay in home/kubernetes/namespace_adoption.tf.

import {
  to = module.home.module.kubernetes.module.namespace["cert-manager"].kubernetes_namespace_v1.this
  id = "cert-manager"
}

import {
  to = module.home.module.kubernetes.module.namespace["crossplane-system"].kubernetes_namespace_v1.this
  id = "crossplane-system"
}

import {
  to = module.home.module.kubernetes.module.namespace["default"].kubernetes_namespace_v1.this
  id = "default"
}

import {
  to = module.home.module.kubernetes.module.namespace["gitlab-agent"].kubernetes_namespace_v1.this
  id = "gitlab-agent"
}

import {
  to = module.home.module.kubernetes.module.namespace["headlamp"].kubernetes_namespace_v1.this
  id = "headlamp"
}

import {
  to = module.home.module.kubernetes.module.namespace["knative-operator"].kubernetes_namespace_v1.this
  id = "knative-operator"
}

import {
  to = module.home.module.kubernetes.module.namespace["kube-node-lease"].kubernetes_namespace_v1.this
  id = "kube-node-lease"
}

import {
  to = module.home.module.kubernetes.module.namespace["kube-public"].kubernetes_namespace_v1.this
  id = "kube-public"
}

import {
  to = module.home.module.kubernetes.module.namespace["kube-system"].kubernetes_namespace_v1.this
  id = "kube-system"
}

import {
  to = module.home.module.kubernetes.module.namespace["kyverno"].kubernetes_namespace_v1.this
  id = "kyverno"
}

import {
  to = module.home.module.kubernetes.module.namespace["medik8s-leases"].kubernetes_namespace_v1.this
  id = "medik8s-leases"
}

import {
  to = module.home.module.kubernetes.module.namespace["node-healthcheck-operator-system"].kubernetes_namespace_v1.this
  id = "node-healthcheck-operator-system"
}

import {
  to = module.home.module.kubernetes.module.namespace["osemu-ehis-farms"].kubernetes_namespace_v1.this
  id = "osemu-ehis-farms"
}

import {
  to = module.home.module.kubernetes.module.namespace["shdrch"].kubernetes_namespace_v1.this
  id = "shdrch"
}

import {
  to = module.home.module.kubernetes.module.namespace["wasmcloud-system"].kubernetes_namespace_v1.this
  id = "wasmcloud-system"
}

import {
  to = module.home.module.kubernetes.module.namespace["aether-k8s-arch-labeler"].kubernetes_namespace_v1.this
  id = "aether-k8s-arch-labeler"
}

import {
  to = module.home.module.kubernetes.module.namespace["aether-k8s-node-remediator"].kubernetes_namespace_v1.this
  id = "aether-k8s-node-remediator"
}

import {
  to = module.home.module.kubernetes.module.namespace["agent-sandbox-system"].kubernetes_namespace_v1.this
  id = "agent-sandbox-system"
}

import {
  to = module.home.module.kubernetes.module.namespace["cilium-secrets"].kubernetes_namespace_v1.this
  id = "cilium-secrets"
}

import {
  to = module.home.module.kubernetes.module.namespace["colony-dev"].kubernetes_namespace_v1.this
  id = "colony-dev"
}

import {
  to = module.home.module.kubernetes.module.namespace["colony-sandboxes-dev"].kubernetes_namespace_v1.this
  id = "colony-sandboxes-dev"
}

