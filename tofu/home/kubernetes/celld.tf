# =============================================================================
# celld — self-hosted, distributed Durable Objects (denoland/celld v0.2.0)
# =============================================================================
# Each object is a SQLite DB replicated to the Ceph RGW bucket "celld";
# bucket CAS (If-None-Match/If-Match) is the fencing mechanism — verified
# against s3.home.shdr.ch before deployment (RGW conditional-write probe).
# Nodes are disposable: local PVC is a hibernation cache, the bucket is truth.
# One bucket = one fleet = one deployed Worker application.
#
# v0.2.0 splits the data plane (--listen) from peer/operator traffic
# (--internal-listen / --advertise). A v0.1.0 command line with a non-loopback
# --listen refuses to start. Mixed v0.1.0/v0.2.0 fleets are unsupported: stop
# every v0.1.0 node before starting v0.2.0.
#
# Telemetry (CELLD_OTEL) is a v0.2.0 feature. Traces and console logs export
# OTLP/HTTP protobuf to the in-cluster daemonset collector, which stamps
# k8s attributes and forwards to Tempo/Loki. The fleet bucket is not used as
# a Parquet sink — that prefix would share the CAS/lease bucket.

locals {
  celld_version = "0.2.0" # release tag
  # v0.2.0 also publishes multi-arch sha-<commit>; pin the amd64 artifact
  # because the cluster is mixed-arch and the node selector is amd64.
  celld_image         = "ghcr.io/denoland/celld:3f22aedd1ea4d413b93e84afb1ce385f04be84f1-amd64"
  celld_ns            = module.namespace["celld"].name
  celld_labels        = { app = "celld" }
  celld_host          = "celld.home.shdr.ch"
  celld_port          = 8080
  celld_internal_port = 8081
  celld_bucket        = "celld"
  celld_endpoint      = "https://s3.home.shdr.ch"
  celld_region        = "us-east-1"
  celld_otlp_endpoint = "http://otel-daemonset-opentelemetry-collector.observability.svc.cluster.local:4318"
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

# Headless: stable DNS for --advertise (celld-0.celld-peer...:internal).
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
    port {
      port        = local.celld_internal_port
      target_port = local.celld_internal_port
      name        = "internal"
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
            "--internal-listen", "0.0.0.0:${local.celld_internal_port}",
            "--advertise", "$(POD_NAME).celld-peer.${local.celld_ns}.svc.cluster.local:${local.celld_internal_port}",
          ]
          env_from {
            secret_ref { name = kubernetes_secret_v1.celld_s3.metadata[0].name }
          }
          env {
            name  = "CELLD_WATCH"
            value = "/var/lib/celld/state"
          }
          env {
            name  = "CELLD_OTEL"
            value = "1"
          }
          env {
            name  = "CELLD_OTEL_SINK"
            value = "otlp"
          }
          env {
            # OTLP sink: short flush for near-live Tempo/Loki (docs default is 5m).
            name  = "CELLD_OTEL_FLUSH_MS"
            value = "10000"
          }
          env {
            name  = "OTEL_SERVICE_NAME"
            value = "celld"
          }
          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = local.celld_otlp_endpoint
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
          port {
            container_port = local.celld_internal_port
            name           = "internal"
          }
          volume_mount {
            name       = "state"
            mount_path = "/var/lib/celld"
          }
          readiness_probe {
            http_get {
              path = "/__celld/health"
              port = local.celld_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/__celld/health"
              port = local.celld_port
            }
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

# Assay-pattern CNP: gateway ingress on the public listener + same-namespace
# peer HTTP on the internal listener. Egress stays unrestricted (cluster
# baseline is non-denying; celld needs s3.home.shdr.ch:443, OTLP :4318, and
# peer DNS, all covered by the baseline).
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
          toPorts = [{ ports = [
            { port = "${local.celld_port}", protocol = "TCP" },
            { port = "${local.celld_internal_port}", protocol = "TCP" },
          ] }]
        },
      ]
    }
  }
}
