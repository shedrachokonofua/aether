# =============================================================================
# Namespace contract registry (54 live namespaces)
# =============================================================================
# Single writer for aether.shdr.ch/* contract labels. Per-app namespace
# resources are retired via moved/import blocks in namespace_adoption.tf.

locals {
  namespace_contract_specs = {
    "aether-k8s-arch-labeler" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Legacy arch-labeler webhook (Phase 2 delete)",
      source_file             = "tofu/home/kubernetes/aether_k8s_arch_labeler.tf"
      extra_labels = {
        "app.kubernetes.io/name" = "aether-k8s-arch-labeler"
      }
    }
    "aether-k8s-node-remediator" = {
      tier                    = "platform",
      owner                   = "node-remediator",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Node remediation controller (adopt split-brain)",
      source_file             = "tofu/home/kubernetes/node_remediation.tf"
      extra_labels = {
        "app.kubernetes.io/name" = "aether-k8s-node-remediator"
      }
    }
    "affine" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "critical",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/affine.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "affine.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "agent-sandbox-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Agent Sandbox controller",
      source_file             = "tofu/home/kubernetes/agent_sandbox.tf"
    }
    "ceph-csi-cephfs" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/ceph_csi_fs.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "cert-manager" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/cert_manager.tf"
      extra_labels = {
        "name" = "cert-manager"
      }
    }
    "cilium-secrets" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Cilium structural namespace"
      extra_labels = {
        "app.kubernetes.io/managed-by" = "Helm"
        "app.kubernetes.io/part-of"    = "cilium"
      }
      extra_annotations = {
        "meta.helm.sh/release-name"      = "cilium"
        "meta.helm.sh/release-namespace" = "kube-system"
      }
    }
    "cnpg-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/cnpg.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "restricted"
        "pod-security.kubernetes.io/audit"   = "restricted"
        "pod-security.kubernetes.io/warn"    = "restricted"
      }
    }
    "coder" = {
      tier                    = "agent",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/coder.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "coder.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "colony-dev" = {
      tier                    = "guest",
      owner                   = "colony",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      description             = "Colony sibling repo workloads"
      extra_labels = {
        "app.kubernetes.io/managed-by" = "opentofu"
        "app.kubernetes.io/part-of"    = "colony"
        "colony.shdr.ch/environment"   = "dev"
      }
    }
    "colony-sandboxes-dev" = {
      tier                    = "sandbox",
      owner                   = "colony",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Colony sandboxes"
      extra_labels = {
        "app.kubernetes.io/component"  = "agent-sandbox"
        "app.kubernetes.io/managed-by" = "opentofu"
        "app.kubernetes.io/name"       = "colony-sandboxes"
        "app.kubernetes.io/part-of"    = "colony"
        "colony.shdr.ch/environment"   = "dev"
        "colony.shdr.ch/purpose"       = "agent-sandboxes"
      }
    }
    "crossplane-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/crossplane.tf"
      extra_labels = {
        "name" = "crossplane-system"
      }
    }
    "dawarich" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "critical",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/dawarich.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "dawarich.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "default" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Gateway residue namespace"
    }
    "descheduler" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/descheduler.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "restricted"
      }
    }
    "deskplane" = {
      tier                    = "agent",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/deskplane.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "deskplane.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled"   = "true"
        "pod-security.kubernetes.io/enforce" = "baseline"
      }
    }
    "games" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "lan-vip",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/game_server.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      },
      extra_annotations = {
        "aether.shdr.ch/data" = "rebuildable"
      }
    }
    "gitlab-agent" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/gitlab_agent.tf"
      extra_labels = {
        "name" = "gitlab-agent"
      }
    }
    "gitlab-runner" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/gitlab_runner.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "globalping" = {
      tier                    = "guest",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/globalping.tf",
      egress                  = "internet",
      registry_access         = "dockerhub",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
        "goldilocks.fairwinds.com/enabled"   = "false"
      }
    }
    "goldilocks" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/goldilocks.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "restricted"
      }
    }
    "headlamp" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "internal"
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/headlamp.tf",
      hostnames = [
        "headlamp.home.shdr.ch",
      ]
      extra_labels = {
        "name" = "headlamp"
      }
    }
    "holyclaude" = {
      tier                    = "agent",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/holyclaude.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "holyclaude.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled"   = "true"
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "hoppscotch" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/hoppscotch.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "hoppscotch.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "immich" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "critical",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/immich.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "immich.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "hermes" = {
      tier                    = "agent",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = true,
      source_file             = "tofu/home/kubernetes/hermes.tf",
      egress                  = "allowlist",
      registry_access         = "dockerhub",
      hostnames = [
        "beryl.home.shdr.ch",
        "beryl-dashboard.home.shdr.ch",
        "tungsten.home.shdr.ch",
        "tungsten-dashboard.home.shdr.ch",
      ],
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "baseline"
      }
    }
    "infra" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/namespaces.tf",
      egress                  = "internal",
      mesh                    = "ambient",
      registry_access         = "dockerhub",
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
        "istio.io/dataplane-mode"          = "ambient"
      }
    }
    "mnemo" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "critical",
      exposure                = "internal",
      create_s3_backup_secret = true,
      source_file             = "tofu/home/kubernetes/mnemo.tf",
      egress                  = "allowlist",
      registry_access         = "gitlab"
      hostnames = [
        "mnemo.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled"   = "true"
        "pod-security.kubernetes.io/enforce" = "baseline"
      }
    }
    "istio-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/istio.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "karakeep" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/karakeep.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "karakeep.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "kepler" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/security_observability.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "knative-operator" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/knative.tf"
      extra_labels = {
        "name" = "knative-operator"
      }
    }
    "knative-serving" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/knative.tf"
      extra_labels = {
        "app.kubernetes.io/name"    = "knative-serving"
        "app.kubernetes.io/version" = "1.20.0"
      }
    }
    "kube-node-lease" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Kubernetes structural namespace"
    }
    "kube-public" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Kubernetes structural namespace"
    }
    "kube-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Kubernetes system namespace",
      hostnames = [
        "hubble.home.shdr.ch",
      ],
      extra_labels = {
        "aether.shdr.ch/gateway-access" = "internal"
      }
    }
    "kyverno" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/kyverno.tf"
      extra_labels = {
        "name" = "kyverno"
      }
    }
    "matrix" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "critical",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/matrix.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "matrix.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "media" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "public",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/jellyfin.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "tv.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled"   = "true"
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "medik8s-leases" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Medik8s operator lease namespace"
    }
    "miniflux" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/miniflux.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "miniflux.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "nextcloud" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "critical",
      exposure                = "public",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/nextcloud.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "nextcloud.home.shdr.ch",
        "nextcloud-public.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "node-healthcheck-operator-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Node healthcheck operator",
      source_file             = "tofu/home/kubernetes/node_remediation.tf"
      extra_labels = {
        "app.kubernetes.io/component" = "controller-manager"
        "app.kubernetes.io/name"      = "node-healthcheck-operator"
      }
    }
    "open-design" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/open_design.tf",
      hostnames = [
        "open-design.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "osemu-ehis-farms" = {
      tier                    = "guest",
      owner                   = "osemu-ehis-farms",
      backup                  = "critical",
      exposure                = "tunnel",
      create_s3_backup_secret = false,
      description             = "Client WordPress site"
      registry_access         = "dockerhub",
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
        "istio.io/dataplane-mode"          = "ambient"
      }
    }
    "personal" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/personal_apps.tf",
      egress                  = "internal",
      registry_access         = "dockerhub",
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "vaultwarden" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "critical",
      exposure                = "internal",
      create_s3_backup_secret = true,
      source_file             = "tofu/home/kubernetes/vaultwarden.tf",
      egress                  = "internal",
      registry_access         = "dockerhub",
      hostnames = [
        "vaultwarden.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "policy-reporter" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/security_observability.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "restricted"
      }
    }
    "sandboxes" = {
      tier                    = "sandbox",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/agent_sandbox.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce"         = "restricted"
        "pod-security.kubernetes.io/enforce-version" = "latest"
        "pod-security.kubernetes.io/warn"            = "restricted"
        "pod-security.kubernetes.io/audit"           = "restricted"
      }
    }
    "shdrch" = {
      tier                    = "guest",
      owner                   = "shdrch",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      description             = "Sibling shdrch workloads"
      extra_labels = {
        "app.kubernetes.io/name" = "shdrch"
      }
    }
    "system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/ceph_csi.tf",
      registry_access         = "dockerhub",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "temporal" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/temporal.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "temporal.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
    "tetragon" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/security_observability.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "trivy-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/security_observability.tf",
      extra_labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
    "vc-seven30" = {
      tier                    = "tenant",
      owner                   = "seven30",
      backup                  = "standard",
      exposure                = "public",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/vcluster.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "seven30.home.shdr.ch",
        "seven30-root.home.shdr.ch",
      ]
    }
    "wasmcloud-system" = {
      tier                    = "platform",
      owner                   = "aether",
      backup                  = "none",
      exposure                = "none",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/wasmcloud.tf"
      extra_labels = {
        "name" = "wasmcloud-system"
      }
    }
    "yourspotify" = {
      tier                    = "app",
      owner                   = "aether",
      backup                  = "standard",
      exposure                = "internal",
      create_s3_backup_secret = false,
      source_file             = "tofu/home/kubernetes/yourspotify.tf",
      registry_access         = "dockerhub",
      hostnames = [
        "your-spotify.home.shdr.ch",
        "your-spotify-api.home.shdr.ch",
      ],
      extra_labels = {
        "goldilocks.fairwinds.com/enabled" = "true"
      }
    }
  }
}

module "namespace" {
  for_each = local.namespace_contract_specs

  source = "../modules/namespace"

  name                    = each.key
  tier                    = each.value.tier
  owner                   = each.value.owner
  backup                  = each.value.backup
  exposure                = each.value.exposure
  description             = try(each.value.description, "")
  source_file             = try(each.value.source_file, "")
  hostnames               = try(each.value.hostnames, [])
  egress                  = try(each.value.egress, null)
  mesh                    = try(each.value.mesh, null)
  registry_access         = try(each.value.registry_access, null)
  extra_labels            = try(each.value.extra_labels, {})
  extra_annotations       = try(each.value.extra_annotations, {})
  create_s3_backup_secret = try(each.value.create_s3_backup_secret, false)
}

# Convenience alias for legacy references during migration
locals {
  ns = { for name, mod in module.namespace : name => mod.name }
}
