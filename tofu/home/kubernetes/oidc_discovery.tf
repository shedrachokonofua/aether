# =============================================================================
# OIDC Discovery (anonymous)
# =============================================================================
# Grants the built-in `system:service-account-issuer-discovery` role to the
# `system:unauthenticated` group so the API server returns the OIDC discovery
# document and JWKS without an Authorization header.
#
# Caddy at the home gateway already proxies the two discovery paths from
# https://oidc.k8s.home.shdr.ch (see Caddyfile.j2 oidc.k8s.home.shdr.ch
# block) to the API server VIP, but the API server itself was rejecting
# anonymous requests. Without this binding, RGW (and any other STS verifier)
# cannot fetch the JWKS to validate projected ServiceAccount tokens issued
# under --service-account-issuer=https://oidc.k8s.home.shdr.ch.
#
# Same pattern the seven30 vcluster uses internally (vcluster.tf
# `oidc-discovery-public` ClusterRoleBinding).

resource "kubernetes_cluster_role_binding_v1" "oidc_discovery_public" {
  metadata {
    name = "oidc-discovery-public"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:service-account-issuer-discovery"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "system:unauthenticated"
  }
}
