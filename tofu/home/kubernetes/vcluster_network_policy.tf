# =============================================================================
# CiliumNetworkPolicy: Seven30 vcluster egress boundary
# =============================================================================
# Restricts pods in the Seven30 vcluster from directly accessing Aether
# infrastructure IPs. Allowed Aether services are explicitly allowlisted
# using L7 SNI filtering for Caddy-proxied HTTPS, and L4 FQDN filtering
# for non-HTTP protocols (SSH, SMTP).
#
# SNI filtering inspects the TLS ClientHello to distinguish hostnames on
# the same Caddy IP (10.0.2.2), so bao.home.shdr.ch is allowed while
# grafana.home.shdr.ch is denied — even though both resolve to 10.0.2.2.
#
# Internet access (Discord, OpenRouter, etc.) is unrestricted.
# Intra-cluster communication is unrestricted.

resource "kubernetes_manifest" "seven30_egress_policy" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "seven30-egress-boundary"
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
            ]
            ports = [
              { port = "443", protocol = "TCP" },
            ]
          }]
        },

        # GitLab SSH (not proxied by Caddy, separate IP)
        {
          toFQDNs = [
            { matchName = "ssh.gitlab.home.shdr.ch" },
          ]
          toPorts = [{
            ports = [
              { port = "2222", protocol = "TCP" },
            ]
          }]
        },

        # Gitlab SSH
        {
          toCIDR = ["10.0.3.7/32"]
          toPorts = [{
            ports = [
              { port = "2222", protocol = "TCP" },
            ]
          }]
        },

        # Vaultwarden SMTP (plaintext, no TLS)
        {
          toFQDNs = [
            { matchName = "smtp.home.shdr.ch" },
          ]
          toPorts = [{
            ports = [
              { port = "25", protocol = "TCP" },
            ]
          }]
        },

        # Intra-cluster (pod-to-pod, pod-to-service, host API server)
        {
          toEntities = ["cluster"]
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
