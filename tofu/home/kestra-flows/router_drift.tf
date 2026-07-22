# Nightly router config-drift check (see kestra/flows/router-drift-check.yaml.tftpl).
# The comparison script is injected into the flow as an input file so the flow
# is self-contained and Kestra's dind-less pod runs it with its own python3 via
# the Process task runner - no repo, no router access, no secret exposure.
# Separate file from main.tf so unrelated flow work can land independently.

resource "kestra_flow" "router_drift_check" {
  namespace = "aether.network"
  flow_id   = "router-drift-check"

  content = templatefile("${path.module}/../../../kestra/flows/router-drift-check.yaml.tftpl", {
    script = file("${path.module}/../../../scripts/router-drift.py")
  })
}
