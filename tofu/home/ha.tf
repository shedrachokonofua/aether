# HA group for Ceph-backed workload VMs (Tier 2)
# See docs/exploration/proxmox-ha.md for tier definitions
# Tier 1 groups (oracle-critical, niobe-critical) use local ZFS + replication

resource "proxmox_virtual_environment_hagroup" "ceph_workloads" {
  group   = "ceph-workloads"
  comment = "Tier 2: Ceph-backed workload VMs"

  # Priority order (higher = preferred)
  nodes = {
    trinity = 5  # High capacity, OSD node
    neo     = 4  # High capacity, OSD node
    smith   = 3  # Storage host, OSD node
    niobe   = 2  # Lightweight services
  }

  restricted  = true  # VMs can only run on these nodes
  no_failback = true  # Don't auto-migrate back after recovery
}
