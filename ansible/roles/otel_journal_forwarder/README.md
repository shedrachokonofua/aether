# otel_journal_forwarder

Installs `otel-journal-gatewayd-forwarder` on `monitoring-stack`: a pinned
release from the GitLab generic package registry (version + SHA-256, never
`latest`), verified on download. Renders `config.toml` from
`otel_journal_forwarder_sources` (each `{ name, url, no_tls, labels, units }`)
plus a global `[tls]` block, runs as the dedicated `ojgf` system user under a
hardened `Type=notify` unit, and exposes Prometheus metrics on
`127.0.0.1:9091`.

TLS material (`client.crt`, `client.key`, and the step-ca root `step-root.crt`)
is rendered into `{{ otel_journal_forwarder_tls_dir }}` by the `openbao_agent`
role (vault-agent), not by this role — the role only creates the `ojgf`-readable
directory. `ca_cert` points at the deployed step-ca root by default.

Wired via `ansible/playbooks/monitoring_stack/journal_forwarder.yml`
(`task configure:journal-forwarder`), which also seeds each source's cursor to
the journal tail on fresh deploy.
