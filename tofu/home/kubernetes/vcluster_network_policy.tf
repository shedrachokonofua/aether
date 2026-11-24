# =============================================================================
# CiliumNetworkPolicy: Seven30 vcluster egress boundary
# =============================================================================
# Restricts pods in the Seven30 vcluster from directly accessing Aether
# infrastructure IPs. Allowed Aether services are explicitly allowlisted
# using L7 SNI filtering for Caddy-proxied HTTPS, and L4 IP filtering
# for non-HTTP protocols (SSH, SMTP).
#
# SNI filtering inspects the TLS ClientHello to distinguish hostnames on
# the same Caddy IP (10.0.2.2), so bao.home.shdr.ch is allowed while
# other home services are denied — even though they resolve to 10.0.2.2.
#
# Split into two policies because Cilium 1.19+ does not allow mixing
# toEntities/toEndpoints with toCIDR/toCIDRSet in the same policy.
#
# Internet access (Discord, OpenRouter, etc.) is unrestricted.
# Intra-cluster communication is unrestricted.

# Policy 1: Entity + endpoint rules (cluster-internal, DNS)
resource "kubernetes_manifest" "seven30_egress_internal" {
  depends_on = [helm_release.cilium]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "seven30-egress-internal"
      namespace = local.vcluster_namespace
    }
    spec = {
      endpointSelector = {}

      egress = [
        {
          toEndpoints = [{
            matchLabels = {
              "io.kubernetes.pod.namespace" = "kube-system"
              "k8s-app"                     = "kube-dns"
            }
          }]
          toPorts = [{
            ports = [
              { port = "53", protocol = "ANY" },
            ]
          }]
        },

        # Intra-cluster (pod-to-pod, pod-to-service, host API server)
        {
          toEntities = ["cluster"]
        },
      ]
    }
  }
}

# Policy 2: CIDR rules (Aether services, internet)
resource "kubernetes_manifest" "seven30_egress_external" {
  depends_on = [helm_release.cilium]

  field_manager {
    force_conflicts = true
  }

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "seven30-egress-external"
      namespace = local.vcluster_namespace
    }
    spec = {
      endpointSelector = {}

      egress = [
        # Allowlisted Aether services — L7 SNI filtering on Caddy IP
        {
          toCIDR = ["10.0.2.2/32"]
          toPorts = [{
            serverNames = [
              "bao.home.shdr.ch",
              "litellm.home.shdr.ch",
              "gitlab.home.shdr.ch",
              "auth.shdr.ch",
              "s3.home.shdr.ch",
              "otel.home.shdr.ch",
              "grafana.home.shdr.ch",
              "**.seven30.xyz",
            ]
            ports = [
              { port = "443", protocol = "TCP" },
            ]
          }]
        },

        # Rotating SOCKS5 proxy (same VM as Caddy, plain TCP)
        {
          toCIDR = ["10.0.2.2/32"]
          toPorts = [{
            ports = [
              { port = "1080", protocol = "TCP" },
            ]
          }]
        },

        # GitLab SSH (10.0.3.7 = ssh.gitlab.home.shdr.ch)
        {
          toCIDR = ["10.0.3.7/32"]
          toPorts = [{
            ports = [
              { port = "2222", protocol = "TCP" },
            ]
          }]
        },

        # Vaultwarden SMTP (10.0.3.4 = smtp.home.shdr.ch)
        {
          toCIDR = ["10.0.3.4/32"]
          toPorts = [{
            ports = [
              { port = "25", protocol = "TCP" },
            ]
          }]
        },

        # Internet — all public IPs except Aether private ranges
        {
          toCIDRSet = [{
            cidr   = "0.0.0.0/0"
            except = ["10.0.0.0/16", "192.168.2.0/24"]
          }]
        },
      ]
    }
  }
}
