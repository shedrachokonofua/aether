# Dedicated issuing CA for the journal forwarder's client certificate.
#
# The intermediate is generated in OpenBao and signed once by the step-ca root
# outside Tofu (see docs/exploration/journal-forwarder.md). Tofu owns the mount,
# short-lived issuing role, and the narrowly scoped machine-auth grant.

resource "vault_mount" "pki_journal_client" {
  path                      = "pki-journal-client"
  type                      = "pki"
  description               = "Journal gateway client certificates"
  default_lease_ttl_seconds = 259200
  # Five years for the signed intermediate; leaf certificates are constrained
  # by the role below.
  max_lease_ttl_seconds = 157680000
}

resource "vault_pki_secret_backend_role" "journal_forwarder" {
  backend            = vault_mount.pki_journal_client.path
  name               = "forwarder"
  allowed_domains    = ["otel-journal-gatewayd-forwarder"]
  allow_bare_domains = true
  client_flag        = true
  server_flag        = false
  key_type           = "ec"
  key_bits           = 256
  ttl                = 259200
  max_ttl            = 604800
  allow_ip_sans      = false
  enforce_hostnames  = true
  key_usage          = ["DigitalSignature", "KeyAgreement"]
  ext_key_usage      = ["ClientAuth"]
  require_cn         = true
  no_store           = false
}

resource "vault_policy" "journal_forwarder" {
  name = "journal-forwarder"

  policy = <<-EOT
    path "pki-journal-client/issue/forwarder" {
      capabilities = ["create", "update"]
    }
  EOT
}

# Do not add this policy to vault_cert_auth_backend_role.aether_machine. The
# shared role accepts every *.home.shdr.ch machine certificate and would let
# any fleet machine mint a journal-reading credential.
resource "vault_cert_auth_backend_role" "journal_forwarder" {
  backend              = vault_auth_backend.cert.path
  name                 = "journal-forwarder"
  certificate          = data.http.step_ca_root.response_body
  token_policies       = [vault_policy.journal_forwarder.name]
  allowed_common_names = ["monitoring-stack.home.shdr.ch"]
  token_ttl            = 3600
  token_max_ttl        = 86400
}
