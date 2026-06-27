# Globalping Probe namespace with Privileged Pod Security Standard
# Host network access (hostNetwork=true) requires privileged namespace policies
resource "kubernetes_namespace_v1" "globalping" {
  metadata {
    name = "globalping"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

# Globalping Probe - self-hosted network diagnostics probe
# Earns testing credits for the homelab by contributing outbound network measurements
resource "kubernetes_deployment_v1" "globalping_probe" {
  metadata {
    name      = "globalping-probe"
    namespace = kubernetes_namespace_v1.globalping.metadata[0].name
    labels = {
      app = "globalping-probe"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "globalping-probe"
      }
    }

    template {
      metadata {
        labels = {
          app = "globalping-probe"
        }
      }

      spec {
        host_network = true # Runs on the host network for accurate network latency tests

        container {
          name  = "globalping-probe"
          image = "globalping/globalping-probe:latest"

          env {
            name  = "GP_ADOPTION_TOKEN"
            value = var.secrets["globalping_adoption_token"]
          }

          resources {
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }
      }
    }
  }
}
