# =============================================================================
# Tetragon TracingPolicies — runtime security baseline (OBSERVE-ONLY)
# =============================================================================
# All policies use matchActions: Post only — nothing is killed or blocked. They
# emit process_kprobe events to the existing stdout->Loki/Prometheus pipeline.
#
# Scope note: Tetragon's eBPF runs in the HOST kernel, so it cannot see inside
# Kata-isolated pods (guest VM, separate kernel). Today only the `infra`
# namespace runs Kata; the untrusted tiers scoped below (Coder, GitLab CI,
# vcluster, colony sandboxes) are runc and fully visible.
#
# Phase 2 (not yet enabled): external egress + interpreter-exec policies (noisy
# for AI-agent workloads) and selective enforcement (Sigkill/Override) on the
# runc tier — Override additionally requires CONFIG_BPF_KPROBE_OVERRIDE, which
# must be verified on the Talos kernel first.
#
# Schema verified against Tetragon v1.7 via `kubectl apply --dry-run=server`.

locals {
  # Untrusted, runc-based (Tetragon-visible) namespaces for tighter scoping.
  tetragon_untrusted_namespaces = [
    "coder",
    "gitlab-runner",
    "vc-seven30",
    "colony-sandboxes-dev",
  ]
}

# F. Kernel module load from any pod (non-host pidns) — near-zero false positives.
resource "kubectl_manifest" "tetragon_kernel_module_load" {
  depends_on = [helm_release.tetragon]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata   = { name = "tetragon-kernel-module-load" }
    spec = {
      kprobes = [
        {
          call    = "security_kernel_module_request"
          syscall = false
          return  = true
          message = "Automatic kernel module load requested by a pod"
          tags    = ["security.kernel-module"]
          args    = [{ index = 0, type = "string" }]
          returnArg = { index = 0, type = "int" }
          selectors = [{
            matchNamespaces = [{ namespace = "Pid", operator = "NotIn", values = ["host_ns"] }]
            matchActions    = [{ action = "Post" }]
          }]
        },
        {
          call    = "security_kernel_read_file"
          syscall = false
          return  = true
          message = "Explicit kernel module load (finit_module) by a pod"
          tags    = ["security.kernel-module"]
          args    = [{ index = 0, type = "file" }, { index = 1, type = "int" }]
          returnArg = { index = 0, type = "int" }
          selectors = [{
            matchArgs       = [{ index = 1, operator = "Equal", values = ["2"] }]
            matchNamespaces = [{ namespace = "Pid", operator = "NotIn", values = ["host_ns"] }]
            matchActions    = [{ action = "Post" }]
          }]
        },
      ]
    }
  })
}

# D. Unprivileged user-namespace creation (container-escape primitive) — clean signal.
resource "kubectl_manifest" "tetragon_unprivileged_userns" {
  depends_on = [helm_release.tetragon]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata   = { name = "tetragon-unprivileged-userns-create" }
    spec = {
      kprobes = [{
        call    = "create_user_ns"
        syscall = false
        message = "Unprivileged user namespace created"
        tags    = ["security.container-escape"]
        args    = [{ index = 0, type = "nop" }]
        selectors = [{
          matchCapabilities = [{
            type                 = "Effective"
            operator             = "NotIn"
            isNamespaceCapability = false
            values               = ["CAP_SYS_ADMIN"]
          }]
          matchActions = [{ action = "Post" }]
        }]
      }]
    }
  })
}

# B. Pod touching the host container-runtime socket — clean escape signal, cluster-wide.
resource "kubectl_manifest" "tetragon_host_runtime_socket" {
  depends_on = [helm_release.tetragon]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata   = { name = "tetragon-host-runtime-socket-access" }
    spec = {
      kprobes = [{
        call    = "security_file_permission"
        syscall = false
        return  = true
        message = "Pod accessed host container-runtime socket"
        tags    = ["security.container-escape"]
        args    = [{ index = 0, type = "file" }, { index = 1, type = "int" }]
        returnArg = { index = 0, type = "int" }
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "Prefix"
            values = [
              "/run/containerd/containerd.sock",
              "/run/docker.sock",
              "/var/run/docker.sock",
              "/run/crio/crio.sock",
            ]
          }]
          matchNamespaces = [{ namespace = "Pid", operator = "NotIn", values = ["host_ns"] }]
          matchActions    = [{ action = "Post", rateLimit = "30s" }]
        }]
      }]
    }
  })
}

# A. Sensitive-file / SA-token access — scoped to untrusted runc namespaces, rate-limited.
resource "kubectl_manifest" "tetragon_sensitive_file_access" {
  depends_on = [helm_release.tetragon]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata   = { name = "tetragon-sensitive-file-access" }
    spec = {
      podSelector = {
        matchExpressions = [{
          key      = "k8s:io.kubernetes.pod.namespace"
          operator = "In"
          values   = local.tetragon_untrusted_namespaces
        }]
      }
      kprobes = [{
        call    = "security_file_permission"
        syscall = false
        return  = true
        message = "Sensitive file access in untrusted workload"
        tags    = ["security.sensitive-files"]
        args    = [{ index = 0, type = "file" }, { index = 1, type = "int" }]
        returnArg = { index = 0, type = "int" }
        selectors = [{
          matchArgs = [{
            index    = 0
            operator = "Prefix"
            values = [
              "/etc/shadow",
              "/etc/sudoers",
              "/etc/ssh/",
              "/root/.ssh/",
              "/var/run/secrets/kubernetes.io/serviceaccount",
              "/run/secrets/kubernetes.io/serviceaccount",
              "/root/.kube/config",
            ]
          }]
          matchActions = [{ action = "Post", rateLimit = "1m" }]
        }]
      }]
    }
  })
}

# C. Privilege escalation (setuid root + sensitive capability gain) — scoped untrusted.
resource "kubectl_manifest" "tetragon_privilege_escalation" {
  depends_on = [helm_release.tetragon]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata   = { name = "tetragon-privilege-escalation" }
    spec = {
      podSelector = {
        matchExpressions = [{
          key      = "k8s:io.kubernetes.pod.namespace"
          operator = "In"
          values   = local.tetragon_untrusted_namespaces
        }]
      }
      kprobes = [
        {
          call    = "sys_setuid"
          syscall = true
          message = "setuid(0) - escalation to root"
          tags    = ["security.privilege-escalation"]
          args    = [{ index = 0, type = "int" }]
          selectors = [{
            matchArgs    = [{ index = 0, operator = "Equal", values = ["0"] }]
            matchActions = [{ action = "Post", rateLimit = "1m" }]
          }]
        },
        {
          call    = "commit_creds"
          syscall = false
          message = "Process gained sensitive effective capability"
          tags    = ["security.privilege-escalation"]
          args    = [{ index = 0, type = "cred" }]
          selectors = [{
            matchCapabilityChanges = [{
              type                 = "Effective"
              operator             = "In"
              isNamespaceCapability = false
              # CAP_DAC_OVERRIDE omitted: not recognized by Tetragon v1.7's capability parser.
              values               = ["CAP_SYS_ADMIN", "CAP_SETUID", "CAP_SYS_PTRACE"]
            }]
            matchActions = [{ action = "Post", rateLimit = "1m" }]
          }]
        },
      ]
    }
  })
}

# E. Mount / pivot_root / setns — namespace & mount manipulation, scoped untrusted.
resource "kubectl_manifest" "tetragon_mount_namespace_ops" {
  depends_on = [helm_release.tetragon]

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v1alpha1"
    kind       = "TracingPolicy"
    metadata   = { name = "tetragon-mount-namespace-ops" }
    spec = {
      podSelector = {
        matchExpressions = [{
          key      = "k8s:io.kubernetes.pod.namespace"
          operator = "In"
          values   = local.tetragon_untrusted_namespaces
        }]
      }
      kprobes = [
        {
          call    = "sys_mount"
          syscall = true
          message = "mount() in untrusted workload"
          tags    = ["security.namespace-ops"]
          args    = [{ index = 0, type = "string" }, { index = 1, type = "string" }]
          selectors = [{ matchActions = [{ action = "Post", rateLimit = "30s" }] }]
        },
        {
          call    = "sys_pivot_root"
          syscall = true
          message = "pivot_root() in untrusted workload"
          tags    = ["security.namespace-ops"]
          args    = [{ index = 0, type = "string" }, { index = 1, type = "string" }]
          selectors = [{ matchActions = [{ action = "Post" }] }]
        },
        {
          call    = "sys_setns"
          syscall = true
          message = "setns() - joining a namespace"
          tags    = ["security.namespace-ops"]
          args    = [{ index = 0, type = "int" }, { index = 1, type = "int" }]
          selectors = [{ matchActions = [{ action = "Post" }] }]
        },
      ]
    }
  })
}
