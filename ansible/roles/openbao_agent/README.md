# openbao_agent

Ansible port of `nix/modules/openbao-agent.nix` for Ansible-managed VMs. Obtains
a step-ca machine certificate (`machine-bootstrap` provisioner) with a
`step ca renew --daemon` unit, installs `step` + `bao`, and runs `bao agent`
(`vault-agent.service`) authenticating to OpenBao via the cert auth method.

`auto_auth` uses the caller-supplied `openbao_agent_auth_role` (a **dedicated,
CN-scoped** cert-auth role — never the shared `aether-machine`).
`openbao_agent_templates` is a list of vault-agent `template` stanzas
(`{ destination, contents, perms, owner, group, command }`), so a caller can mint
short-lived secrets and restart consumers on renewal.

First established for the journal forwarder: the parent play passes a template
that issues `pki-journal-client/issue/forwarder` (PKCS#8) and writes the
forwarder's client cert/key. Pattern is reusable for other secret consumers on
Ansible-managed VMs.
