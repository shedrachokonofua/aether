# =============================================================================
# celld — self-hosted, distributed Durable Objects (denoland/celld v0.1.0)
# =============================================================================
# Each object is a SQLite DB replicated to the Ceph RGW bucket "celld";
# bucket CAS (If-None-Match/If-Match) is the fencing mechanism — verified
# against s3.home.shdr.ch before deployment (RGW conditional-write probe).
# Nodes are disposable: local PVC is a hibernation cache, the bucket is truth.
# One bucket = one fleet = one deployed Worker application.

locals {
  celld_version = "0.1.0" # release tag
  # v0.1.0's GHCR image is architecture-suffixed; pin the amd64 artifact because
  # the release has no multi-architecture manifest and the cluster is mixed-arch.
  celld_image    = "ghcr.io/denoland/celld:553ae73f83c87c3f7c7a5f73c32c2211d9d7341f-amd64"
  celld_ns       = module.namespace["celld"].name
  celld_labels   = { app = "celld" }
  celld_host     = "celld.home.shdr.ch"
  celld_port     = 8080
  celld_bucket   = "celld"
  celld_endpoint = "https://s3.home.shdr.ch"
  celld_region   = "us-east-1"
}

resource "kubernetes_secret_v1" "celld_s3" {
  depends_on = [module.namespace["celld"]]
  metadata {
    name      = "celld-s3"
    namespace = local.celld_ns
    labels    = local.celld_labels
  }
  data = {
    AWS_ACCESS_KEY_ID     = var.secrets["ceph.celld_s3_access_key"]
    AWS_SECRET_ACCESS_KEY = var.secrets["ceph.celld_s3_secret_key"]
  }
  type = "Opaque"
}

# Headless: gives each pod stable DNS for --advertise (celld-0.celld-peer...).
resource "kubernetes_service_v1" "celld_peer" {
  depends_on = [module.namespace["celld"]]
  metadata {
    name      = "celld-peer"
    namespace = local.celld_ns
    labels    = local.celld_labels
  }
  spec {
    cluster_ip = "None"
    selector   = local.celld_labels
    port {
      port        = local.celld_port
      target_port = local.celld_port
      name        = "http"
    }
  }
}

resource "kubernetes_stateful_set_v1" "celld" {
  depends_on = [kubernetes_secret_v1.celld_s3, kubernetes_service_v1.celld_peer]
  # celld exits until a Worker deployment exists in the bucket; the Worker is
  # deployed after IaC creates the fleet, so readiness is verified explicitly.
  wait_for_rollout = false
  metadata {
    name      = "celld"
    namespace = local.celld_ns
    labels    = local.celld_labels
  }
  spec {
    service_name = kubernetes_service_v1.celld_peer.metadata[0].name
    replicas     = 2
    selector { match_labels = local.celld_labels }
    template {
      metadata { labels = local.celld_labels }
      spec {
        enable_service_links = false
        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }
        container {
          name  = "celld"
          image = local.celld_image
          args = [
            "--bucket", "s3://${local.celld_bucket}",
            "--endpoint", local.celld_endpoint,
            "--region", local.celld_region,
            "--listen", "0.0.0.0:${local.celld_port}",
            "--advertise", "$(POD_NAME).celld-peer.${local.celld_ns}.svc.cluster.local:${local.celld_port}",
          ]
          env_from {
            secret_ref { name = kubernetes_secret_v1.celld_s3.metadata[0].name }
          }
          env {
            name  = "CELLD_WATCH"
            value = "/var/lib/celld/state"
          }
          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }
          port {
            container_port = local.celld_port
            name           = "http"
          }
          volume_mount {
            name       = "state"
            mount_path = "/var/lib/celld"
          }
          readiness_probe {
            tcp_socket { port = local.celld_port }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket { port = local.celld_port }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
        }
      }
    }
    volume_claim_template {
      metadata { name = "state" }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
        resources { requests = { storage = "1Gi" } }
      }
    }
  }
  lifecycle {
    # Kyverno owns priorityClassName via namespace-tier defaulting; ignoring only this field prevents perpetual Terraform rollouts and immutable Job replacements.
    ignore_changes = [spec[0].template[0].spec[0].priority_class_name]
  }
}

# Client traffic: any node answers and proxies to the cell owner internally.
resource "kubernetes_service_v1" "celld" {
  depends_on = [kubernetes_stateful_set_v1.celld]
  metadata {
    name      = "celld"
    namespace = local.celld_ns
    labels    = local.celld_labels
  }
  spec {
    selector = local.celld_labels
    port {
      port        = local.celld_port
      target_port = local.celld_port
      name        = "http"
    }
  }
}

resource "kubernetes_manifest" "celld_route" {
  depends_on = [kubernetes_manifest.main_gateway, kubernetes_service_v1.celld]
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "celld", namespace = local.celld_ns }
    spec = {
      parentRefs = [{ name = "main-gateway", namespace = "default" }]
      hostnames  = [local.celld_host]
      rules = [{
        filters = [{
          type = "RequestHeaderModifier"
          requestHeaderModifier = {
            set = [
              { name = "X-Forwarded-Proto", value = "https" },
              { name = "X-Forwarded-Host", value = local.celld_host },
            ]
          }
        }]
        backendRefs = [{ name = "celld", port = local.celld_port }]
      }]
    }
  }
}

# Assay-pattern CNP: gateway ingress + same-namespace peer HTTP. Egress stays
# unrestricted (cluster baseline is non-denying; celld needs s3.home.shdr.ch:443
# and peer DNS, both covered by the baseline).
resource "kubernetes_manifest" "celld_netpol" {
  depends_on = [kubernetes_manifest.cilium_cluster_baseline_network, kubernetes_stateful_set_v1.celld]
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "celld-ingress"
      namespace = local.celld_ns
    }
    spec = {
      endpointSelector = { matchLabels = local.celld_labels }
      ingress = [
        {
          fromEntities = ["ingress"]
          toPorts      = [{ ports = [{ port = "${local.celld_port}", protocol = "TCP" }] }]
        },
        {
          fromEndpoints = [{
            matchLabels = { "io.kubernetes.pod.namespace" = local.celld_ns }
          }]
          toPorts = [{ ports = [{ port = "${local.celld_port}", protocol = "TCP" }] }]
        },
      ]
    }
  }
}
