# =============================================================================
# cloud-audit namespace — vigil (cloud control-plane audit forwarder)
# =============================================================================
# Namespace contract entry lives in namespace_contracts.tf ("cloud-audit").
# The namespace + vigil ServiceAccount landed with the auth-chain work
# (see git history); this file is the P2 deployment: config, cursor PVC,
# digest-pinned serve Deployment, Kyverno pod-spec pin, Cilium egress pin.
#
# vigil design contract: vigil repo PLAN.md (auth: federated-jwt SA token,
# Bao runtime fetch — nothing static, nothing in etcd).

locals {
  vigil_image = "registry.gitlab.home.shdr.ch/so/vigil@sha256:f9a4d0721e966cf13885cbe432fcad7608ec67a17deee94a070d95c276f7d2d1"
  vigil_ns    = module.namespace["cloud-audit"].name

  vigil_config_toml = <<-EOT
    state_dir = "/var/lib/vigil"

    [otlp]
    endpoint = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318"

    [keycloak]
    url = "https://auth.shdr.ch"
    realm = "aether"
    client_id = "cloud-audit"
    method = "federated-jwt"
    sa_token_path = "/var/run/secrets/tokens/keycloak"

    [bao]
    url = "https://bao.home.shdr.ch"
    jwt_path = "jwt-cloud-audit"
    jwt_role = "cloud-audit"
    sa_token_path = "/var/run/secrets/tokens/bao"
    secret_path = "kv/data/aether/cloud-audit"

    [aws]
    role_arn = "${var.cloud_audit.aws_role_arn}"
    region = "${var.cloud_audit.aws_region}"

    [gcp]
    project_id = "${var.cloud_audit.gcp_project_id}"
    workload_identity_provider = "${var.cloud_audit.gcp_wif_provider}"
    service_account = "${var.cloud_audit.gcp_service_account}"

    [oci]
    region = "ca-toronto-1"
    identity_domain_url = "${var.cloud_audit.oci_domain_url}"
    tenancy_ocid = "${var.cloud_audit.oci_tenancy_ocid}"

    [tailscale]
    tailnet = "${var.cloud_audit.tailnet}"

    [cloudflare]
    account_id = "${var.cloud_audit.cloudflare_account_id}"

    # cloudflare.audit stays disabled until the audit-logs token lands
    # (tofu/cloudflare_cloud_audit.tf gate).

    [collectors."aws.cloudtrail"]
    enabled = true

    [collectors."aws.access_analyzer"]
    enabled = true

    [collectors."aws.ses_stats"]
    enabled = true

    [collectors."gcp.audit"]
    enabled = true

    [collectors."oci.audit"]
    enabled = true

    [collectors."tailscale.state"]
    enabled = true

    [collectors."cloudflare.audit"]
    enabled = false
  EOT
}

# --- workload identity -------------------------------------------------------

resource "kubernetes_service_account_v1" "vigil" {
  metadata {
    name      = "vigil"
    namespace = local.vigil_ns
  }
}

# --- config (references only; secrets come from Bao at runtime) --------------

resource "kubernetes_config_map_v1" "vigil_config" {
  metadata {
    name      = "vigil-config"
    namespace = local.vigil_ns
  }
  data = {
    "config.toml" = local.vigil_config_toml
  }
}

# --- cursor PVC (rebuildable; seed-to-now on loss) ---------------------------

resource "kubernetes_persistent_volume_claim_v1" "vigil_cursors" {
  metadata {
    name      = "vigil-cursors"
    namespace = local.vigil_ns
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

# --- deployment (single replica; the RWO PVC enforces singleton) --------------

resource "kubernetes_deployment_v1" "vigil" {
  metadata {
    name      = "vigil"
    namespace = local.vigil_ns
    labels = {
      "app.kubernetes.io/name" = "vigil"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "vigil"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "vigil"
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.vigil.metadata[0].name
        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          fs_group        = 65534
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "vigil"
          image = local.vigil_image
          args  = ["serve", "--config", "/etc/vigil/config.toml"]
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 65534
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/vigil"
            read_only  = true
          }
          volume_mount {
            name       = "tokens"
            mount_path = "/var/run/secrets/tokens"
            read_only  = true
          }
          volume_mount {
            name       = "cursors"
            mount_path = "/var/lib/vigil"
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.vigil_config.metadata[0].name
          }
        }
        # Projected SA tokens, one per audience the auth chain needs:
        #   keycloak — federated-jwt client assertion (realm issuer URL)
        #   bao      — OpenBao JWT login
        volume {
          name = "tokens"
          projected {
            sources {
              service_account_token {
                path               = "keycloak"
                audience           = "https://auth.shdr.ch/realms/aether"
                expiration_seconds = 600
              }
            }
            sources {
              service_account_token {
                path               = "bao"
                audience           = "https://bao.home.shdr.ch"
                expiration_seconds = 600
              }
            }
          }
        }
        volume {
          name = "cursors"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.vigil_cursors.metadata[0].name
          }
        }
        termination_grace_period_seconds = 90
      }
    }
  }
}

# --- Kyverno pod-spec pin ----------------------------------------------------
# The ONLY pod allowed in cloud-audit: the digest-pinned vigil Deployment.
# Nothing else may run here — no secret mounts, no other SA, no other image.

resource "kubectl_manifest" "cloud_audit_pod_pin" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1alpha1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "cloud-audit-pod-pin"
      annotations = {
        "policies.kyverno.io/title"       = "cloud-audit pod pin"
        "policies.kyverno.io/category"    = "Security"
        "policies.kyverno.io/subject"     = "Pod"
        "policies.kyverno.io/description" = "Only the digest-pinned vigil pod may exist in cloud-audit: fixed image digest, the vigil SA, no secret mounts, no command/args override, no privilege escalation."
      }
    }
    spec = {
      failurePolicy     = "Fail"
      validationActions = ["Deny"]
      matchConstraints = {
        namespaceSelector = {
          matchLabels = { "kubernetes.io/metadata.name" = local.vigil_ns }
        }
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["pods"]
          scope       = "Namespaced"
        }]
      }
      validations = [
        {
          expression = "object.spec.serviceAccountName == 'vigil'"
          message    = "pods in cloud-audit must use the vigil service account"
        },
        {
          expression = "object.metadata.labels['app.kubernetes.io/name'] == 'vigil'"
          message    = "pods in cloud-audit must be the vigil workload"
        },
        {
          expression = "object.spec.containers.all(c, c.image == '${local.vigil_image}')"
          message    = "containers in cloud-audit must use the digest-pinned vigil image"
        },
        {
          expression = "!has(object.spec.volumes) || !object.spec.volumes.exists(v, has(v.secret))"
          message    = "no secret volumes are allowed in cloud-audit (Bao runtime fetch only)"
        },
        {
          expression = "object.spec.containers.all(c, !has(c.env) || !c.env.exists(e, has(e.valueFrom) && has(e.valueFrom.secretKeyRef)))"
          message    = "no secretKeyRef env is allowed in cloud-audit (Bao runtime fetch only)"
        },
        {
          expression = "object.spec.containers.all(c, (!has(c.command) || size(c.command) == 0) && has(c.args) && c.args == ['serve', '--config', '/etc/vigil/config.toml'])"
          message    = "no command/args override in cloud-audit (vigil serve only)"
        },
        {
          expression = "has(object.spec.securityContext) && object.spec.securityContext.runAsNonRoot == true && object.spec.containers.all(c, has(c.securityContext) && c.securityContext.allowPrivilegeEscalation == false && c.securityContext.readOnlyRootFilesystem == true)"
          message    = "pods in cloud-audit must run non-root with no privilege escalation and a read-only root filesystem"
        },
      ]
    }
  })
}

# No workload kinds other than the vigil Deployment may exist.
resource "kubectl_manifest" "cloud_audit_workload_pin" {
  depends_on = [helm_release.kyverno]

  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1alpha1"
    kind       = "ValidatingPolicy"
    metadata = {
      name = "cloud-audit-workload-pin"
      annotations = {
        "policies.kyverno.io/title"       = "cloud-audit workload pin"
        "policies.kyverno.io/category"    = "Security"
        "policies.kyverno.io/description" = "Only the vigil Deployment may be created as a workload in cloud-audit."
      }
    }
    spec = {
      failurePolicy     = "Fail"
      validationActions = ["Deny"]
      matchConstraints = {
        namespaceSelector = {
          matchLabels = { "kubernetes.io/metadata.name" = local.vigil_ns }
        }
        resourceRules = [
          {
            apiGroups   = ["apps"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["deployments", "statefulsets", "daemonsets"]
            scope       = "Namespaced"
          },
          {
            apiGroups   = ["batch"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["jobs", "cronjobs"]
            scope       = "Namespaced"
          },
          {
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["replicationcontrollers"]
            scope       = "Namespaced"
          },
        ]
      }
      validations = [{
        expression = "object.metadata.name == 'vigil' && object.kind == 'Deployment'"
        message    = "only the vigil Deployment may exist as a workload in cloud-audit"
      }]
    }
  })
}

# --- Cilium egress pin (the documented reach of the poller) ------------------

resource "kubernetes_manifest" "cloud_audit_egress_pin" {
  depends_on = [helm_release.cilium]

  field_manager { force_conflicts = true }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "vigil-egress"
      namespace = local.vigil_ns
    }
    spec = {
      endpointSelector = {}
      enableDefaultDeny = {
        egress  = true
        ingress = true
      }
      egress = [
        # kube-dns (required for FQDN policies)
        {
          toEndpoints = [{
            matchLabels = {
              "k8s-app"                      = "kube-dns"
              "io.kubernetes.pod.namespace"  = "kube-system"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "UDP" },
              { port = "53", protocol = "TCP" },
            ]
            rules = {
              dns = [{ matchPattern = "*" }]
            }
          }]
        },
        # in-cluster OTLP collector
        {
          toEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"       = "opentelemetry-collector"
              "io.kubernetes.pod.namespace"  = "observability"
            }
          }]
          toPorts = [{ ports = [{ port = "4318", protocol = "TCP" }] }]
        },
        # the exact external reach of the poller
        {
          toFQDNs = [
            { matchName = "auth.shdr.ch" },
            { matchName = "bao.home.shdr.ch" },
            { matchName = "sts.${var.cloud_audit.aws_region}.amazonaws.com" },
            { matchName = "cloudtrail.${var.cloud_audit.aws_region}.amazonaws.com" },
            { matchName = "access-analyzer.${var.cloud_audit.aws_region}.amazonaws.com" },
            { matchName = "email.${var.cloud_audit.aws_region}.amazonaws.com" },
            { matchName = "sts.googleapis.com" },
            { matchName = "iamcredentials.googleapis.com" },
            { matchName = "logging.googleapis.com" },
            { matchName = trimsuffix(trimprefix(var.cloud_audit.oci_domain_url, "https://"), ":443") },
            { matchName = "audit.ca-toronto-1.oraclecloud.com" },
            { matchName = "api.tailscale.com" },
            { matchName = "api.cloudflare.com" },
          ]
          toPorts = [{ ports = [{ port = "443", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
