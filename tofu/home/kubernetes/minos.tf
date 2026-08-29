# =============================================================================
# minos — pre-send contact QA (Stage 1: landing page + waitlist)
#
# Sibling repo /Users/shdrch/projects/minos
# (ssh://git@ssh.gitlab.home.shdr.ch:2222/so/minos.git) owns code, Dockerfile,
# and CI; this file owns every cluster object — the colony split. Keel
# force-polls :latest, so a green main branch redeploys itself.
#
# SvelteKit adapter-node server; the waitlist lives in one SQLite file
# (node:sqlite) on the PVC. Single replica + Recreate: SQLite is not
# multi-writer, and Stage-1 traffic is one operator plus a waitlist.
# =============================================================================

locals {
  minos_ns    = module.namespace["minos"].name
  minos_image = "registry.gitlab.home.shdr.ch/so/minos/web:latest"
  minos_host  = "minos.home.shdr.ch"

  minos_labels = {
    "app.kubernetes.io/name"       = "minos"
    "app.kubernetes.io/part-of"    = "minos"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "minos_data" {
  depends_on = [module.namespace["minos"]]

  metadata {
    name      = "minos-data"
    namespace = local.minos_ns
    labels    = local.minos_labels
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "minos" {
  depends_on = [module.namespace["minos"]]

  metadata {
    name      = "minos"
    namespace = local.minos_ns
    labels    = local.minos_labels
    annotations = {
      "keel.sh/policy"   = "force"
      "keel.sh/trigger"  = "poll"
      "keel.sh/matchTag" = "true"
    }
  }

  spec {
    # Must stay 1: the waitlist SQLite file is not multi-writer.
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "minos"
      }
    }

    template {
      metadata {
        labels = local.minos_labels
      }

      spec {
        automount_service_account_token = false

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        volume {
          name = "minos-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.minos_data.metadata[0].name
          }
        }

        container {
          name              = "web"
          image             = local.minos_image
          image_pull_policy = "Always"

          port {
            name           = "http"
            container_port = 3000
          }

          env {
            name  = "WAITLIST_DB"
            value = "/var/lib/minos/waitlist.db"
          }

          volume_mount {
            name       = "minos-data"
            mount_path = "/var/lib/minos"
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true

            capabilities {
              drop = ["ALL"]
            }
          }

          # No dedicated health endpoint; the landing page itself is the
          # cheapest truthful probe for a static-shell SvelteKit server.
          readiness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations["kubernetes.io/change-cause"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
      # Kyverno and operator rollouts own these pod-template fields.
      spec[0].template[0].spec[0].priority_class_name,
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"],
    ]
  }
}

resource "kubernetes_service_v1" "minos" {
  depends_on = [module.namespace["minos"]]

  metadata {
    name      = "minos"
    namespace = local.minos_ns
    labels    = local.minos_labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "minos"
    }

    port {
      name        = "http"
      port        = 3000
      target_port = "http"
    }
  }
}

resource "kubernetes_manifest" "minos_route" {
  depends_on = [kubernetes_service_v1.minos]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "minos"
      namespace = local.minos_ns
      labels    = local.minos_labels
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = [local.minos_host]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = kubernetes_service_v1.minos.metadata[0].name
          port = 3000
        }]
      }]
    }
  }
}
