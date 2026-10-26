# =============================================================================
# OpenBao Auth & Secrets for Daimyo
# =============================================================================
# Daimyo signs per-org run tokens with OpenBao Transit keys `daimyo-<org>`
# (ES256, spec §7.2) and reads grant secrets from KV `orgs/<org>/…` (spec
# §18.3). `daimyo-server` authenticates with its Kubernetes service-account
# token via the shared `kubernetes-aether` auth backend
# (tofu/home/kubernetes/openbao_kubernetes_auth.tf), so no standing
# credential lives in the cluster.
#
# The Transit mount is literally `transit`: daimyo-identity's TransitSigner
# posts to `v1/transit/sign/daimyo-<org>` and reads
# `v1/transit/keys/daimyo-<org>` (crates/daimyo-identity/src/signer.rs).

locals {
  daimyo_transit_orgs = toset(["personal", "seven30", "qa", "cicada"])
  # KV v2 mount the broker reads (tofu/home/talos_cluster.tf wires
  # `openbao_kv_mount_path = vault_mount.kv.path`, i.e. "kv").
  daimyo_kv_mount = "kv"
}

resource "vault_mount" "daimyo_transit" {
  path        = "transit"
  type        = "transit"
  description = "Transit for Daimyo run-token signing (keys daimyo-<org>, ES256)"
}

resource "vault_transit_secret_backend_key" "daimyo" {
  for_each = local.daimyo_transit_orgs

  backend = vault_mount.daimyo_transit.path
  name    = "daimyo-${each.key}"
  type    = "ecdsa-p256"
}

resource "vault_policy" "daimyo_server" {
  name = "daimyo-server"

  policy = <<-EOT
    # Sign + publish run tokens (keys daimyo-<org>, created above).
    path "transit/sign/daimyo-*" {
      capabilities = ["update"]
    }
    path "transit/keys/daimyo-*" {
      capabilities = ["read"]
    }
    # Static KV read: the vault provider needs child-token rights per resource.
    path "auth/token/create" {
      capabilities = ["update"]
    }
    # Grant secrets under orgs/<org>/… (KV v2 mount `kv`).
    path "${local.daimyo_kv_mount}/data/orgs/*" {
      capabilities = ["read"]
    }
    path "${local.daimyo_kv_mount}/metadata/orgs/*" {
      capabilities = ["read", "list"]
    }
    # Server-only GitLab administrator credential, outside org grant paths.
    path "${local.daimyo_kv_mount}/data/daimyo/gitlab-admin" {
      capabilities = ["read"]
    }
  EOT
}

# Placeholder grant secrets so `orgs/<org>/…` exists before org repos seed
# real ones. The GitLab bot token is empty until the org owner writes
# `orgs/<org>/gitlab` (key `token`); model grants need no KV secret.
resource "vault_kv_secret_v2" "daimyo_org_placeholders" {
  for_each = local.daimyo_transit_orgs

  mount = local.daimyo_kv_mount
  name  = "orgs/${each.key}/gitlab"

  data_json = jsonencode({
    token = ""
  })

  # The org owner writes the real token with `bao kv put`; a later apply
  # must not reset it to the placeholder.
  lifecycle {
    ignore_changes = [data_json]
  }
}

# Bearer token Deskplane's MCP server requires on /mcp (kubernetes/deskplane.tf
# mcp.authTokenSecretRef). LiteLLM's MCP gateway sends it, and each org that
# reaches Deskplane gets a copy at orgs/<org>/deskplane for its mcp grants'
# `auth.secret`. Keep the org list in step with daimyo_deskplane_orgs
# (kubernetes/daimyo.tf), which opens the network path for the same orgs.
resource "random_password" "deskplane_mcp_auth" {
  length  = 48
  special = false
}

resource "vault_kv_secret_v2" "daimyo_deskplane_mcp_auth" {
  for_each = toset(["personal", "qa"])

  mount = local.daimyo_kv_mount
  name  = "orgs/${each.key}/deskplane"

  data_json = jsonencode({
    token = random_password.deskplane_mcp_auth.result
  })
}

# The `orion` agent's LiteLLM virtual key for the MCP gateway's per-server
# routes (kubernetes/orion.tf gateway grants). Registered in LiteLLM through
# its API with key_alias `daimyo-orion` and models ["no-default-models"],
# scoped by object_permission.mcp_servers (register_litellm_virtual_keys.yml
# keeps the scope). Only the Daimyo sidecar holds it, so the agent's shell
# cannot reach gateway servers around its tool policy.
resource "random_password" "orion_litellm_mcp" {
  length  = 48
  special = false
}

resource "vault_kv_secret_v2" "daimyo_orion_litellm_mcp" {
  mount = local.daimyo_kv_mount
  name  = "orgs/personal/litellm-mcp"

  data_json = jsonencode({
    token = "sk-${random_password.orion_litellm_mcp.result}"
  })
}

# ntfy has no auth: the topic name is the only access control, so it is a
# random secret. Orion publishes needsYou feed cards to it (NTFY_TOPIC in
# kubernetes/orion.tf); the Daimyo server policy above already reads
# orgs/*, and this copy documents the value in the org tree.
resource "random_password" "orion_ntfy_topic" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "daimyo_orion_ntfy" {
  mount = local.daimyo_kv_mount
  name  = "orgs/personal/orion-ntfy"

  data_json = jsonencode({
    topic = random_password.orion_ntfy_topic.result
  })
}

# The server presents its ServiceAccount token (created by the chart's rbac)
# to the shared `kubernetes-aether` backend — the claude_bridge pattern.
resource "vault_kubernetes_auth_backend_role" "daimyo_server" {
  backend   = "kubernetes-aether"
  role_name = "aether-k8s-daimyo-server"

  bound_service_account_names      = ["daimyo-server"]
  bound_service_account_namespaces = ["daimyo-system"]
  audience                         = "https://bao.home.shdr.ch"

  token_policies = [vault_policy.daimyo_server.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}
