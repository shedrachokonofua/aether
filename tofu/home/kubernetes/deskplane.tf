# =============================================================================
# Deskplane - Kubernetes-native browser desktop broker
# =============================================================================
# Control-plane image + Helm chart are published by the deskplane repo CI to
# registry.gitlab.home.shdr.ch/so/deskplane on main pushes.
#
# Public URL: https://desk.home.shdr.ch

locals {
  deskplane_namespace      = "deskplane"
  deskplane_host           = "desktop.home.shdr.ch"
  deskplane_public_url     = "https://${local.deskplane_host}"
  deskplane_chart_version  = "0.1.0-b21fde90"
  deskplane_image_tag      = "latest"
  deskplane_registry_host  = "registry.gitlab.home.shdr.ch"
  deskplane_registry_user  = var.secrets["gitlab.root_email"]
  deskplane_registry_pass  = var.secrets["gitlab.root_password"]
  deskplane_registry_image = "${local.deskplane_registry_host}/so/deskplane"
  deskplane_node_selector = {
    "kubernetes.io/hostname" = "talos-smith"
  }
  deskplane_mcp_token   = var.secrets["deskplane.mcp_api_token"]
  deskplane_mcp_llm_key = var.secrets["litellm.virtual_keys.deskplane_mcp"]
}


resource "kubernetes_secret_v1" "deskplane_gitlab_registry" {
  depends_on = [module.namespace["deskplane"]]

  metadata {
    name      = "deskplane-gitlab-registry"
    namespace = local.deskplane_namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.deskplane_registry_host) = {
          username = local.deskplane_registry_user
          password = local.deskplane_registry_pass
          auth     = base64encode("${local.deskplane_registry_user}:${local.deskplane_registry_pass}")
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "deskplane_oidc" {
  depends_on = [module.namespace["deskplane"]]

  metadata {
    name      = "deskplane-oidc"
    namespace = local.deskplane_namespace
  }

  data = {
    client-secret = var.deskplane_oauth_client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "deskplane_mcp_token" {
  depends_on = [module.namespace["deskplane"]]
  metadata {
    name      = "deskplane-mcp-token"
    namespace = local.deskplane_namespace
  }
  data = {
    token = local.deskplane_mcp_token
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "deskplane_mcp_llm_key" {
  depends_on = [module.namespace["deskplane"]]
  metadata {
    name      = "deskplane-mcp-llm-key"
    namespace = local.deskplane_namespace
  }
  data = {
    api-key = local.deskplane_mcp_llm_key
  }
  type = "Opaque"
}

resource "helm_release" "deskplane" {
  depends_on = [
    module.namespace["deskplane"],
    kubernetes_secret_v1.deskplane_gitlab_registry,
    kubernetes_secret_v1.deskplane_oidc,
    kubernetes_secret_v1.deskplane_mcp_token,
    kubernetes_secret_v1.deskplane_mcp_llm_key,
    kubernetes_storage_class_v1.ceph_rbd,
    kubernetes_manifest.main_gateway,
  ]

  name          = "deskplane"
  repository    = "oci://${local.deskplane_registry_host}/so/deskplane"
  chart         = "deskplane"
  namespace     = local.deskplane_namespace
  version       = local.deskplane_chart_version
  wait          = true
  wait_for_jobs = false
  atomic        = true
  timeout       = 900

  values = [yamlencode({
    image = {
      repository = local.deskplane_registry_image
      tag        = local.deskplane_image_tag
      pullPolicy = "Always"
    }

    imagePullSecrets = [{
      name = kubernetes_secret_v1.deskplane_gitlab_registry.metadata[0].name
    }]

    publicURL = local.deskplane_public_url

    oidc = {
      issuerURL       = var.oidc_issuer_url
      clientID        = "deskplane"
      existingSecret  = kubernetes_secret_v1.deskplane_oidc.metadata[0].name
      clientSecretKey = "client-secret"
      redirectURL     = "${local.deskplane_public_url}/auth/callback"
    }

    gateway = {
      enabled = true
      host    = local.deskplane_host
      parentRef = {
        namespace = "default"
        name      = "main-gateway"
      }
    }

    persistence = {
      storageClassName = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
    }

    profiles = [
      {
        name = "default"
        resources = {
          requests = {
            cpu    = "500m"
            memory = "1Gi"
          }
          limits = {
            cpu    = "4"
            memory = "8Gi"
          }
        }
        nodeSelector = local.deskplane_node_selector
      },
      {
        name             = "gpu"
        runtimeClassName = "nvidia"
        resources = {
          requests = {
            cpu              = "500m"
            memory           = "1Gi"
            "nvidia.com/gpu" = "1"
          }
          limits = {
            cpu              = "4"
            memory           = "8Gi"
            "nvidia.com/gpu" = "1"
          }
        }
        nodeSelector = local.deskplane_node_selector
        tolerations = [
          {
            key      = "nvidia.com/gpu"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
      }
    ]

    catalog = {
      images = [
        {
          name = "chrome", displayName = "Chrome", image = "kasmweb/chrome:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name = "firefox", displayName = "Firefox", image = "kasmweb/firefox:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name = "brave", displayName = "Brave", image = "kasmweb/brave:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name = "kali", displayName = "Kali Linux", image = "kasmweb/core-kali-rolling:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name = "tor", displayName = "Tor Browser", image = "kasmweb/tor-browser:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name = "terminal", displayName = "Terminal", image = "kasmweb/desktop:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name = "dosbox-x", displayName = "DOS (DOSBox-X)", image = "${local.deskplane_registry_image}/dosbox-x-kasm:latest"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name = "win9x", displayName = "Windows 95 / 98", image = "${local.deskplane_registry_image}/win9x-qemu-kasm:latest"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1", WIN9X_DISK_URL = "", WIN9X_DISK_SHA256 = "" }
        },
        {
          name = "cua-ubuntu", displayName = "Computer-Use Desktop", image = "docker.io/trycua/cua-ubuntu:0.1.4"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true, controlPort = 8000 }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        }
      ]
    }

    apiTokensSecretRef = [
      {
        name     = kubernetes_secret_v1.deskplane_mcp_token.metadata[0].name
        key      = "token"
        subject  = "svc:deskplane-mcp"
        username = "deskplane-mcp"
      }
    ]

    adminSubjects = []

    mcp = {
      enabled = true
      image = {
        repository = "${local.deskplane_registry_image}/mcp"
        tag        = local.deskplane_image_tag
      }
      env = {
        DESKPLANE_API_URL             = "http://deskplane-serve.deskplane.svc.cluster.local:8080"
        DESKPLANE_PUBLIC_URL          = local.deskplane_public_url
        DESKPLANE_MCP_IMAGE_REF       = "cua-ubuntu"
        DESKPLANE_MCP_MODEL           = "router/minimax-m3"
        DESKPLANE_MCP_OPENAI_BASE_URL = "http://litellm.litellm.svc.cluster.local:4000/v1"
      }
      apiTokenSecretRef = {
        name = kubernetes_secret_v1.deskplane_mcp_token.metadata[0].name
        key  = "token"
      }
      openaiApiKeySecretRef = {
        name = kubernetes_secret_v1.deskplane_mcp_llm_key.metadata[0].name
        key  = "api-key"
      }
      controlPort = 8000
    }
  })]
}

# Keel opt-in for the chart-produced Deployments (controller + serve both run
# the so/deskplane image). The chart exposes no annotation/label passthrough, so
# attach keel.sh/* config to the live Deployment metadata via server-side apply.
# The field manager owns only these keys, so Keel's keel.sh/update-time +
# kubernetes.io/change-cause writes never fight tofu. Registry auth reuses the
# chart's imagePullSecret.
resource "kubernetes_annotations" "deskplane_keel" {
  for_each = toset(["deskplane-controller", "deskplane-serve"])

  depends_on = [helm_release.deskplane]

  api_version = "apps/v1"
  kind        = "Deployment"

  metadata {
    name      = each.value
    namespace = local.deskplane_namespace
  }

  annotations = {
    "keel.sh/policy"   = "force"
    "keel.sh/trigger"  = "poll"
    "keel.sh/matchTag" = "true"
  }

  field_manager = "keel-optin"
  force         = true
}

# =============================================================================
# KVM device plugin — foundation for KVM-backed sessions (e.g. Windows XP+)
# =============================================================================
# generic-device-plugin advertises /dev/kvm and /dev/net/tun as schedulable
# extended resources (devic.es/kvm, devic.es/net-tun) so VM-backed session pods
# can request hardware virtualization WITHOUT privileged or hostPath /dev in the
# session pod. The plugin itself must run privileged to register with the kubelet
# device-plugin socket, so it lives in kube-system (no PSA enforce) rather than
# the baseline-enforced deskplane namespace. Scoped to the amd64 session node.
resource "kubectl_manifest" "deskplane_kvm_device_plugin" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: generic-device-plugin
      namespace: kube-system
      labels:
        app.kubernetes.io/name: generic-device-plugin
        app.kubernetes.io/managed-by: OpenTofu
    spec:
      selector:
        matchLabels:
          app.kubernetes.io/name: generic-device-plugin
      updateStrategy:
        type: RollingUpdate
      template:
        metadata:
          labels:
            app.kubernetes.io/name: generic-device-plugin
        spec:
          priorityClassName: system-node-critical
          nodeSelector:
            kubernetes.io/hostname: talos-smith
          containers:
            - name: generic-device-plugin
              image: ghcr.io/squat/generic-device-plugin@sha256:dc192e164c69b03f156765793a1be62ca437709ae477b27ca7d8f3dcf5021576
              args:
                - --device
                - '{"name":"kvm","groups":[{"paths":[{"path":"/dev/kvm"}]}]}'
                - --device
                - '{"name":"net-tun","groups":[{"paths":[{"path":"/dev/net/tun"}]}]}'
              resources:
                requests:
                  cpu: 50m
                  memory: 10Mi
                limits:
                  cpu: 50m
                  memory: 20Mi
              ports:
                - containerPort: 8080
                  name: http
              securityContext:
                privileged: true
              volumeMounts:
                - name: device-plugin
                  mountPath: /var/lib/kubelet/device-plugins
                - name: dev
                  mountPath: /dev
          volumes:
            - name: device-plugin
              hostPath:
                path: /var/lib/kubelet/device-plugins
            - name: dev
              hostPath:
                path: /dev
  YAML
}
