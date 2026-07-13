# gigahub_exporter

Installs `gigahub-exporter` on `monitoring-stack`: a pinned release from the
GitLab generic package registry (version + SHA-256, never `latest`), verified on
download. The exporter performs a read-only remote scrape of the Bell GigaHub
CPE (`192.168.2.1`) over HTTP and exposes Prometheus metrics on
`127.0.0.1:9343`, running as the dedicated `gigahub-exporter` system user under a
hardened `Type=notify` unit.

Admin credentials come from the SOPS inventory (`secrets.gigahub.admin_username`
/ `secrets.gigahub.admin_password`), rendered to root-owned, group-readable files
under `{{ gigahub_exporter_creds_dir }}` (`no_log`), never inlined in config. A
read-only `gigahub-exporter check` preflight gates the play before the unit is
(re)started, and readiness is confirmed via `/readyz`.

Metrics are collected by the node `vm_monitoring_agent` OTel collector via the
`prometheus_scrape_configs` inventory var on `monitoring-stack` (pushed OTLP to
the central collector, scraped by Prometheus's `otel-metrics` job) — **not** the
pod Prometheus. There is no exposed pod port.

Wired via `ansible/playbooks/monitoring_stack/gigahub_exporter.yml`
(`task configure:gigahub-exporter`); use `task deploy:gigahub-exporter` to also
refresh the node agent scrape config.

## Updating the pin

Bump `gigahub_exporter_version` and `gigahub_exporter_sha256` (from the release's
`SHA256SUMS`, `gigahub-exporter-linux-amd64` line) in `defaults/main.yml`, then
redeploy.
