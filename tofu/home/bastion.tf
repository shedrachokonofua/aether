# =============================================================================
# Bastion LXC: tofu-managed secrets pushed to OpenBao
# =============================================================================
# The LXC itself is provisioned via Ansible from the NixOS base image
# (ansible/playbooks/bastion). On the Bao side, this file mints the
# oauth2-proxy cookie secret and reads back the Keycloak client secret, then
# writes both to kv/aether/bastion where the openbao-agent template on the
# host renders them into /run/secrets/oauth2-proxy.env.

resource "random_password" "bastion_oauth2_cookie" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "bastion" {
  mount = vault_mount.kv.path
  name  = "aether/bastion"

  data_json = jsonencode({
    oauth2_proxy_client_secret = keycloak_openid_client.bastion.client_secret
    oauth2_proxy_cookie_secret = random_password.bastion_oauth2_cookie.result
  })
}
