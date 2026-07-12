# Certificate monitoring role

This opt-in role installs pinned standalone exporters for explicit X.509 files
and selected systemd renewal units. It is consumed by `vm_monitoring_agent` for
Ansible-managed VMs. It never scans a directory or reads private keys by
default; callers must list certificate files explicitly.

The x509 exporter exposes certificate validity metrics on `127.0.0.1:9793`.
When renewal units are configured, systemd exporter exposes selected unit state
on `127.0.0.1:9558`. The VM monitoring role adds both endpoints to the local
OTEL Prometheus receiver.
