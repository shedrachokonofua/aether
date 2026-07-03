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
  deskplane_chart_version  = "0.1.0-663dfcfc"
  deskplane_image_tag      = "latest"
  deskplane_registry_host  = "registry.gitlab.home.shdr.ch"
  deskplane_registry_user  = var.secrets["gitlab.root_email"]
  deskplane_registry_pass  = var.secrets["gitlab.root_password"]
  deskplane_registry_image = "${local.deskplane_registry_host}/so/deskplane"
  deskplane_node_selector = {
    "kubernetes.io/hostname" = "talos-smith"
  }
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

resource "helm_release" "deskplane" {
  depends_on = [
    module.namespace["deskplane"],
    kubernetes_secret_v1.deskplane_gitlab_registry,
    kubernetes_secret_v1.deskplane_oidc,
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

    catalog = {
      images = [
        {
          name        = "chrome"
          displayName = "Chrome"
          image       = "kasmweb/chrome:1.17.0"
          runtime = {
            type          = "kasmvnc"
            port          = 6901
            scheme        = "https"
            passwordEnv   = "VNC_PW"
            skipTLSVerify = true
          }
          persistence = {
            defaultMountPath = "/home/kasm-user"
          }
          environment = {
            KASM_SVC_AUDIO   = "1"
            KASM_SVC_UPLOADS = "1"
          }
        },
        {
          name        = "firefox"
          displayName = "Firefox"
          image       = "kasmweb/firefox:1.17.0"
          runtime = {
            type          = "kasmvnc"
            port          = 6901
            scheme        = "https"
            passwordEnv   = "VNC_PW"
            skipTLSVerify = true
          }
          persistence = {
            defaultMountPath = "/home/kasm-user"
          }
          environment = {
            KASM_SVC_AUDIO   = "1"
            KASM_SVC_UPLOADS = "1"
          }
        },
        {
          name        = "brave"
          displayName = "Brave"
          image       = "kasmweb/brave:1.17.0"
          runtime = {
            type          = "kasmvnc"
            port          = 6901
            scheme        = "https"
            passwordEnv   = "VNC_PW"
            skipTLSVerify = true
          }
          persistence = {
            defaultMountPath = "/home/kasm-user"
          }
          environment = {
            KASM_SVC_AUDIO   = "1"
            KASM_SVC_UPLOADS = "1"
          }
        },
        {
          name        = "kali"
          displayName = "Kali Linux"
          image       = "kasmweb/core-kali-rolling:1.17.0"
          runtime = {
            type          = "kasmvnc"
            port          = 6901
            scheme        = "https"
            passwordEnv   = "VNC_PW"
            skipTLSVerify = true
          }
          persistence = {
            defaultMountPath = "/home/kasm-user"
          }
          environment = {
            KASM_SVC_AUDIO   = "1"
            KASM_SVC_UPLOADS = "1"
          }
        },
        {
          name        = "tor"
          displayName = "Tor Browser"
          image       = "kasmweb/tor-browser:1.17.0"
          runtime = {
            type          = "kasmvnc"
            port          = 6901
            scheme        = "https"
            passwordEnv   = "VNC_PW"
            skipTLSVerify = true
          }
          persistence = {
            defaultMountPath = "/home/kasm-user"
          }
          environment = {
            KASM_SVC_AUDIO   = "1"
            KASM_SVC_UPLOADS = "1"
          }
        },
        {
          name        = "terminal"
          displayName = "Terminal"
          image       = "kasmweb/desktop:1.17.0"
          runtime = {
            type          = "kasmvnc"
            port          = 6901
            scheme        = "https"
            passwordEnv   = "VNC_PW"
            skipTLSVerify = true
          }
          persistence = {
            defaultMountPath = "/home/kasm-user"
          }
          environment = {
            KASM_SVC_AUDIO   = "1"
            KASM_SVC_UPLOADS = "1"
          }
        },
      ]
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
  })]
}
