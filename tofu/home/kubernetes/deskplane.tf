# =============================================================================
# Deskplane - Kubernetes-native browser desktop broker
# =============================================================================
# Control-plane image + Helm chart are published by the deskplane repo CI to
# registry.gitlab.home.shdr.ch/so/deskplane on main pushes.
#
# Public URL: https://desk.home.shdr.ch

locals {
  deskplane_namespace     = "deskplane"
  deskplane_host          = "desktop.home.shdr.ch"
  deskplane_public_url    = "https://${local.deskplane_host}"
  deskplane_chart_version = "0.1.0-c0796ff2"
  deskplane_image_tag     = "c0796ff2"
  # CI rebuilds a session image only when images/<name>/** changes and tags
  # it with that pipeline's commit (the push head, not necessarily the commit
  # that touched the image) -- check the registry before bumping.
  deskplane_headless_chromium_tag = "2d2c9e13"
  deskplane_chrome_cdp_tag        = "c0796ff2"
  deskplane_registry_host         = "registry.gitlab.home.shdr.ch"
  deskplane_registry_user         = var.secrets["gitlab.root_email"]
  deskplane_registry_pass         = var.secrets["gitlab.root_password"]
  deskplane_registry_image        = "${local.deskplane_registry_host}/so/deskplane"
  deskplane_node_selector = {
    "kubernetes.io/hostname" = "talos-smith"
  }
  deskplane_mcp_token   = var.secrets["deskplane.mcp_api_token"]
  deskplane_mcp_llm_key = var.secrets["litellm.virtual_keys.deskplane_mcp"]

  # The rotating SOCKS5 proxy runs on the home gateway VM, which is also the
  # Caddy that fronts s3.seaweed.home.shdr.ch (SeaweedFS S3 + STS).
  deskplane_gateway_vm_ip       = split(":", var.rotating_proxy_addr)[0]
  deskplane_rotating_proxy_port = tonumber(split(":", var.rotating_proxy_addr)[1])
  # Web-engine proxy tier, applied per browser context inside the session
  # pods; proxy=auto retries a blocked page once through the first entry.
  deskplane_web_proxies = [
    {
      name = "aether-rotating"
      url  = "socks5://${var.rotating_proxy_addr}"
    },
  ]
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

# Fernet key for saved browser profiles (encrypted storage state in the
# object store). Losing it makes existing profiles unreadable, nothing more.
resource "random_bytes" "deskplane_web_profile_key" {
  length = 32
}

# HMAC secret signing monitor/job webhook deliveries.
resource "random_password" "deskplane_web_webhook_secret" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "deskplane_web" {
  depends_on = [module.namespace["deskplane"]]
  metadata {
    name      = "deskplane-web"
    namespace = local.deskplane_namespace
  }
  data = {
    proxies = jsonencode(local.deskplane_web_proxies)
    # Fernet wants URL-safe base64; random_bytes emits the standard alphabet.
    profile-key    = replace(replace(random_bytes.deskplane_web_profile_key.base64, "+", "-"), "/", "_")
    webhook-secret = random_password.deskplane_web_webhook_secret.result
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
    kubernetes_secret_v1.deskplane_web,
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

    # The quota counts the MCP's own sessions too: the web engine keeps a
    # headless browser resident (plus a headful one once that tier is back on),
    # and every agent run adds its own. The MCP reaps its oldest session on a
    # 409, so a tight quota kills in-flight work.
    sessions = {
      maxPerUser = 6
    }

    # v2 egress fences: restricted session pods (headless-chromium, chrome-cdp)
    # get public internet only, and the MCP gets serve, its session control
    # ports, public egress, and the in-cluster peers in mcp.extraEgress.
    networkPolicy = {
      enabled = true
      # The browsers themselves dial the web engine's proxy. The rotating
      # proxy lives on the gateway VM, inside the private ranges the policy
      # otherwise excludes.
      sessionExtraEgress = [{
        to    = [{ ipBlock = { cidr = "${local.deskplane_gateway_vm_ip}/32" } }]
        ports = [{ protocol = "TCP", port = local.deskplane_rotating_proxy_port }]
      }]
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
          name        = "chrome", displayName = "Chrome", image = "kasmweb/chrome:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name        = "firefox", displayName = "Firefox", image = "kasmweb/firefox:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name        = "brave", displayName = "Brave", image = "kasmweb/brave:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name        = "kali", displayName = "Kali Linux", image = "kasmweb/core-kali-rolling:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name        = "tor", displayName = "Tor Browser", image = "kasmweb/tor-browser:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name        = "terminal", displayName = "Terminal", image = "kasmweb/desktop:1.17.0"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name        = "dosbox-x", displayName = "DOS (DOSBox-X)", image = "${local.deskplane_registry_image}/dosbox-x-kasm:latest"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          name        = "win9x", displayName = "Windows 95 / 98", image = "${local.deskplane_registry_image}/win9x-qemu-kasm:latest"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1", WIN9X_DISK_URL = "", WIN9X_DISK_SHA256 = "" }
        },
        {
          name        = "cua-ubuntu", displayName = "Computer-Use Desktop", image = "${local.deskplane_registry_image}/cua-ubuntu-kasm:ceb78035"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true, controlPort = 8000 }
          persistence = { defaultMountPath = "/home/kasm-user" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
        {
          # Headless Chromium: the web engine's browser pool and browser-only
          # agent tasks. Text perception over CDP, no desktop, boots in
          # seconds. The controller TCP-probes the controlPort, and CDP on 9222
          # is the control endpoint itself.
          name  = "headless-chromium", displayName = "Headless Browser"
          image = "${local.deskplane_registry_image}/headless-chromium:${local.deskplane_headless_chromium_tag}"
          runtime = {
            type        = "cdp"
            port        = 9222
            scheme      = "http"
            controlPort = 9222
          }
          network = { egress = "restricted" }
        },
        {
          # Headful Chrome: KasmVNC for a human, CDP for automation. The web
          # engine's headful escalation tier and human-unblock handoff, and
          # the Browser Sandbox for logged-in profiles.
          name        = "chrome-cdp", displayName = "Chrome (agent-controllable)"
          image       = "${local.deskplane_registry_image}/chrome-cdp:${local.deskplane_chrome_cdp_tag}"
          runtime     = { type = "kasmvnc", port = 6901, scheme = "https", passwordEnv = "VNC_PW", skipTLSVerify = true, controlPort = 9222, cdp = true }
          persistence = { defaultMountPath = "/home/kasm-user" }
          network     = { egress = "restricted" }
          environment = { KASM_SVC_AUDIO = "1", KASM_SVC_UPLOADS = "1" }
        },
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

    # The operator may watch any session through /s/* -- including the ones
    # the MCP service creates for agent runs, which is what the task page's
    # live stage embeds. Referenced from the Keycloak resource so the subject
    # can never drift from the actual user id.
    adminSubjects = [var.operator_oidc_subject]

    mcp = {
      enabled = true
      # CI path-filters build:image:mcp to mcp/**, so this tag only advances
      # on commits that touch the MCP. Bumping it in lockstep with the
      # control-plane SHA pins a tag that was never built: the pod cannot
      # pull, never goes Ready, and the atomic release rolls back on timeout.
      image = {
        repository = "${local.deskplane_registry_image}/mcp"
        tag        = "786c95f4"
      }
      # The web secret reaches the MCP as env vars, which only load at pod
      # start; this label rolls the pod when the proxy list changes.
      podLabels = {
        "aether.shdr.ch/web-proxies" = substr(sha256(jsonencode(local.deskplane_web_proxies)), 0, 16)
      }
      nodeSelector = {
        "kubernetes.io/arch" = "amd64"
      }
      env = {
        DESKPLANE_API_URL               = "http://deskplane.deskplane.svc.cluster.local"
        DESKPLANE_PUBLIC_URL            = local.deskplane_public_url
        DESKPLANE_MCP_IMAGE_REF         = "cua-ubuntu"
        DESKPLANE_MCP_BROWSER_IMAGE_REF = "headless-chromium"
        # A model id exactly as the LiteLLM proxy exposes it: deskplane-mcp
        # drives the chat API directly, so no "openai/" litellm-SDK prefix.
        # The web engine's LLM calls (json/summary/extract) use it too.
        DESKPLANE_MCP_MODEL           = "chatgpt/gpt-6.1-sol"
        DESKPLANE_MCP_OPENAI_BASE_URL = "http://litellm.litellm.svc.cluster.local:4000/v1"
        DESKPLANE_MCP_PORT            = "8100"
        # 40 was tuned when every long run was doomed by the stale-screenshot
        # bug, so raising it only bought more flailing. With the settle delay
        # and the agent's carried-forward memory a real multi-page flow makes
        # steady progress and now needs the room: the ServiceOntario booking
        # flow reaches its blocking step around turn 40.
        DESKPLANE_MCP_MAX_TURNS = "80"

        # Flight recorder. Every agent run is written out as a task: the
        # prompt, a frame and the agent's own reasoning per turn, and the
        # final answer. Until this existed a failed run left nothing behind
        # to look at once it ended.
        #
        # Credentials are keyless: the pod exchanges its projected
        # ServiceAccount token for short-lived credentials via SeaweedFS STS,
        # so nothing here is a key and there is no secret to rotate. The
        # role's trust policy pins this pod's ServiceAccount.
        DESKPLANE_MCP_TRACE_S3_ENDPOINT = "https://s3.seaweed.home.shdr.ch"
        DESKPLANE_MCP_TRACE_S3_BUCKET   = "deskplane-traces"
        DESKPLANE_MCP_TRACE_S3_ROLE_ARN = "arn:aws:iam::000000000000:role/DeskplaneTraceWriter"
      }
      apiTokenSecretRef = {
        name = kubernetes_secret_v1.deskplane_mcp_token.metadata[0].name
        key  = "token"
      }
      openaiApiKeySecretRef = {
        name = kubernetes_secret_v1.deskplane_mcp_llm_key.metadata[0].name
        key  = "api-key"
      }
      # 8000 = computer-server (cua-ubuntu), 9222 = CDP (headless-chromium,
      # chrome-cdp); the chart's policies admit the MCP to exactly these.
      controlPorts = [8000, 9222]

      # Web data engine: scrape/crawl/map/search/extract/interact/monitors.
      # Jobs, monitors and profiles persist in the trace bucket (prefix
      # tasks-web) through the same STS identity as the flight recorder.
      web = {
        enabled         = true
        searxngURL      = "http://${kubernetes_service_v1.searxng.metadata[0].name}.${local.searxng_ns}.svc.cluster.local:${local.searxng_port}"
        headfulImageRef = "chrome-cdp"
        headfulPoolSize = 1
        defaultTimezone = "America/Toronto"
        proxiesSecretRef = {
          name = kubernetes_secret_v1.deskplane_web.metadata[0].name
          key  = "proxies"
        }
        profileKeySecretRef = {
          name = kubernetes_secret_v1.deskplane_web.metadata[0].name
          key  = "profile-key"
        }
        webhookSecretRef = {
          name = kubernetes_secret_v1.deskplane_web.metadata[0].name
          key  = "webhook-secret"
        }
      }

      # OTLP/HTTP traces (web.scrape, web.browser_attempt, llm.*, cdp.call)
      # into the node-local collector's traces pipeline -> Tempo.
      otel = {
        endpoint = "http://otel-daemonset-opentelemetry-collector.${module.namespace["observability"].name}.svc.cluster.local:4318"
      }

      # MCP :8100 callers besides deskplane-serve: LiteLLM's MCP gateway and
      # the cluster collector's /metrics scrape (otel_collector.tf).
      ingressFrom = [
        {
          namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.litellm_ns } }
        },
        {
          namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = module.namespace["observability"].name } }
          podSelector       = { matchLabels = { "app.kubernetes.io/instance" = "otel-cluster" } }
        },
      ]

      # In-cluster and gateway-VM peers the public-egress policy's private-CIDR
      # exclusion would otherwise cut: the LLM gateway, SearXNG, the OTLP
      # collector, and SeaweedFS S3/STS behind Caddy on the gateway VM.
      extraEgress = [
        {
          to    = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.litellm_ns } } }]
          ports = [{ protocol = "TCP", port = local.litellm_port }]
        },
        {
          to    = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.searxng_ns } } }]
          ports = [{ protocol = "TCP", port = local.searxng_port }]
        },
        {
          to = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = module.namespace["observability"].name } }
            podSelector       = { matchLabels = { "app.kubernetes.io/instance" = "otel-daemonset" } }
          }]
          ports = [{ protocol = "TCP", port = 4318 }]
        },
        {
          to    = [{ ipBlock = { cidr = "${local.deskplane_gateway_vm_ip}/32" } }]
          ports = [{ protocol = "TCP", port = 443 }]
        },
      ]
    }
  })]
}

# The chart's session-isolation policy admits deskplane-serve to session pods
# only on the desktop ports (6901/3001), but serve also dials the control port:
# the Browser Sandbox CDP proxy (/api/sessions/{n}/cdp) and the /s/* watch
# proxy for runtime.type=cdp images both go to 9222. NetworkPolicies are
# additive, so this restores exactly that path. Created after the release so
# session pods never sit behind this rule alone.
resource "kubernetes_manifest" "deskplane_serve_session_control" {
  depends_on = [helm_release.deskplane]

  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "deskplane-serve-session-control"
      namespace = local.deskplane_namespace
    }
    spec = {
      podSelector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "deskplane"
          "app.kubernetes.io/component" = "session"
        }
      }
      policyTypes = ["Ingress"]
      ingress = [{
        from = [{
          podSelector = {
            matchLabels = {
              "app.kubernetes.io/name"      = "deskplane"
              "app.kubernetes.io/component" = "serve"
            }
          }
        }]
        ports = [{ protocol = "TCP", port = 9222 }]
      }]
    }
  }
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
