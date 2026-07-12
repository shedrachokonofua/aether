# journal_gateway

Configures `systemd-journal-gatewayd` on agent-free hosts so the journal
forwarder can pull their logs.

Two modes, selected by `journal_gateway_tls_enabled`:

- **TLS (Proxmox hosts)** — gatewayd serves plain HTTP on
  `127.0.0.1:{{ journal_gateway_backend_port }}`; **ghostunnel** terminates
  client-cert mTLS on `{{ journal_gateway_bind_address }}:19531`. Debian systemd
  is openssl-built (`-GNUTLS`), so gatewayd's own `--trust` is unavailable.
  ghostunnel verifies the client cert against the `pki-journal-client`
  intermediate as a trust anchor (Go accepts intermediate anchors without the
  root) plus an `--allow-cn` allowlist. The step-ca server cert is issued via the
  `machine-bootstrap` provisioner (SAN = mgmt IP + FQDN) and auto-renewed by a
  `step ca renew --daemon` unit that restarts ghostunnel. The trust bundle is
  fetched from the mount's public CA endpoint on the controller (the hypervisors
  cannot reach the routed bao endpoint); rotation = add old+new via
  `journal_gateway_extra_trust_pems`.
- **Plain (cloud VMs)** — gatewayd binds the routed WireGuard site IP directly
  (`FreeBind`); WireGuard + nftables + the VyOS `CLOUD` zone are the authn
  boundary. No TLS.

Required: `journal_gateway_bind_address` (and, in TLS mode, the step-ca
provisioner password via `secrets.step_ca.provisioner_password`).
