# =============================================================================
# Orion QA browser (Coder workspaces)
# =============================================================================
# Orion development runs in Coder workspaces (NixOS, no Docker, no fontconfig),
# where a locally launched Chromium would not render like CI. This is the same
# Playwright image Orion's CI visual-qa job uses, serving `playwright run-server`,
# so screenshots taken from a workspace match the committed Linux baselines.
#
# Orion's QA runner connects with
#   QA_BROWSER_WS_ENDPOINT=ws://orion-qa-browser.coder.svc.cluster.local:3000
#   QA_SNAPSHOT_PLATFORM=linux
# and Playwright forwards the browser's loopback traffic (qa.localhost) back over
# that connection (exposeNetwork '<loopback>'), so the app under test stays bound
# to 127.0.0.1 in the workspace. The version must match Orion's @playwright/test.

locals {
  orion_qa_browser_version = "1.64.1"
  orion_qa_browser_labels  = { "app.kubernetes.io/name" = "orion-qa-browser" }
}

resource "kubernetes_deployment_v1" "orion_qa_browser" {
  depends_on = [module.namespace["coder"]]

  metadata {
    name      = "orion-qa-browser"
    namespace = local.coder_namespace
    labels    = local.orion_qa_browser_labels
  }

  spec {
    replicas = 1
    selector {
      match_labels = local.orion_qa_browser_labels
    }
    template {
      metadata {
        labels = local.orion_qa_browser_labels
      }
      spec {
        container {
          name        = "playwright"
          image       = "mcr.microsoft.com/playwright:v${local.orion_qa_browser_version}-noble"
          working_dir = "/home/pwuser"
          command     = ["/bin/sh", "-c", "exec npx -y playwright@${local.orion_qa_browser_version} run-server --port 3000 --host 0.0.0.0"]

          # The coder namespace enforces PodSecurity "restricted"; Playwright's
          # Chromium runs without its own sandbox, so nothing more is needed.
          security_context {
            run_as_user                = 1001 # pwuser in the Playwright image
            run_as_non_root            = true
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }

          port {
            name           = "ws"
            container_port = 3000
          }

          # One browser per connected QA run; several worktrees may run at once.
          # QA audits long tasks (> 50 ms), so CFS throttling distorts results: at
          # a 4-CPU limit three concurrent runs were throttled in 20% of periods.
          resources {
            requests = { cpu = "1", memory = "2Gi" }
            limits   = { cpu = "12", memory = "8Gi" }
          }

          readiness_probe {
            tcp_socket {
              port = 3000
            }
            period_seconds = 10
          }

          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
        }

        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Gi"
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "orion_qa_browser" {
  depends_on = [module.namespace["coder"]]

  metadata {
    name      = "orion-qa-browser"
    namespace = local.coder_namespace
    labels    = local.orion_qa_browser_labels
  }

  spec {
    selector = local.orion_qa_browser_labels
    port {
      name        = "ws"
      port        = 3000
      target_port = "ws"
    }
  }
}

# An unauthenticated browser driver: only Coder workspaces may connect.
resource "kubernetes_network_policy_v1" "orion_qa_browser" {
  depends_on = [module.namespace["coder"]]

  metadata {
    name      = "orion-qa-browser"
    namespace = local.coder_namespace
  }

  spec {
    pod_selector {
      match_labels = local.orion_qa_browser_labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector {}
      }
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }
  }
}
