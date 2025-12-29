# Ceph Distributed Storage Exploration

Exploration of Ceph for distributed, self-healing storage with RPO=0.

## Goal

Replace the current NFS + RAID0 architecture with distributed storage that:

1. Survives any single node failure without data loss (RPO=0)
2. Provides automatic failover (no manual intervention)
3. Eliminates the RAID0 single point of failure on Smith

## Current State

### Storage Architecture

```
Smith (RAID0 NVMe)
       │
   8TB usable
       │
   NFS exports
       │
   ┌───┴───┐
   ▼       ▼
Most VMs  Boot from NFS
```

### Problems

| Issue                 | Impact                                         |
| --------------------- | ---------------------------------------------- |
| RAID0 on Smith        | Single drive failure = all NFS data lost       |
| Smith as SPOF         | Smith node failure = all NFS-backed VMs freeze |
| Async replication RPO | 15-min data loss window during failover        |

## Proposed Architecture

### Three-Tier Storage Model

```
┌────────────────────────────────────────────────────────────────────┐
│                        CEPH (24TB raw / 8-12TB usable)             │
│                        Distributed, HA, RPO=0                      │
│                                                                    │
│    Smith              Trinity              Neo                     │
│    ┌─────┐            ┌─────┐            ┌─────┐                   │
│    │ 4TB │            │ 8TB │            │ 8TB │                   │
│    ├─────┤            │ OSD │            │ OSD │                   │
│    │ 4TB │            └─────┘            └─────┘                   │
│    └─────┘                                                         │
│    MON + MGR          MON + MGR          MON + MGR                 │
│                                                                    │
│    Workload VMs: gitlab, dokploy, ai-tool-stack, dokku,            │
│                  messaging, iot, smallweb, dev-workstation, etc.   │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│                   LOCAL (ZFS, Proxmox replication)                 │
│                   Independent of Ceph for critical path           │
│                                                                    │
│    Oracle: vyos-router, home-gateway-stack, keycloak,              │
│            step-ca, openbao                                        │
│            → Replicate to Trinity                                  │
│                                                                    │
│    Niobe:  monitoring-stack                                        │
│            → Replicate to Trinity                                  │
│                                                                    │
│    Neo:    gpu-workstation (local, no replication, can't HA)       │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│                   COLD (Smith HDD RAID10, 28TB)                    │
│                   Bulk storage, already redundant                  │
│                                                                    │
│    PBS, SeaweedFS, media files, personal data                      │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Why Three Tiers?

### Ceph Tier (Hot, Distributed)

For VMs that benefit from HA and can tolerate Ceph dependency:

| VM                       | Why Ceph                   |
| ------------------------ | -------------------------- |
| gitlab                   | HA good, not critical path |
| dokploy                  | HA good                    |
| ai-tool-stack            | HA good                    |
| dokku                    | HA good                    |
| messaging-stack          | HA good                    |
| iot-management-stack     | HA good                    |
| dev-workstation          | HA good                    |
| smallweb, cockpit, coupe | Small, HA nice             |

### Local Tier (Critical Infrastructure)

VMs that must survive Ceph problems:

| VM                 | Why Local                                   |
| ------------------ | ------------------------------------------- |
| vyos-router        | Network must work if Ceph has quorum issues |
| home-gateway-stack | DNS/proxy must survive storage problems     |
| keycloak           | Identity is critical path                   |
| step-ca            | PKI must boot without cluster dependencies  |
| openbao            | Secrets manager is critical path            |
| monitoring-stack   | Must alert WHEN Ceph has problems           |
| gpu-workstation    | 1TB disk, can't HA anyway (GPU passthrough) |

### Cold Tier (Bulk Storage)

Data that doesn't need HA:

- PBS backups (can wait for Smith to return)
- SeaweedFS S3 (object storage)
- Media files (Jellyfin can buffer)
- Personal data (not real-time critical)

## Capacity Planning

### Hardware Requirements

| Node      | Current NVMe | Upgrade | Final        |
| --------- | ------------ | ------- | ------------ |
| Smith     | 2x 4TB       | None    | 8TB (2 OSDs) |
| Trinity   | 1TB          | +2x 4TB | 8TB (2 OSDs) |
| Neo       | 2TB          | +2x 4TB | 8TB (2 OSDs) |
| **Total** | 11TB         | +16TB   | **24TB raw** |

**Key insight:** With Ceph, Smith is no longer "the storage node"—all three nodes are equal storage participants. This eliminates Smith as a single point of failure.

### Usable Capacity

| Replication Mode   | Usable Capacity | Overhead |
| ------------------ | --------------- | -------- |
| 3x replication     | 8TB             | 66%      |
| 2+1 erasure coding | ~12TB           | 50%      |

### Current VM Needs (Ceph Tier Only)

| VMs                                                                                                   | Total Disk |
| ----------------------------------------------------------------------------------------------------- | ---------- |
| gitlab, dokploy, ai-tool-stack, dokku, messaging, iot, dev-workstation, smallweb, cockpit, coupe, ups | ~1.5TB     |

**Headroom:** 6.5-10.5TB free for growth, snapshots, and buffer.

## Ceph Components

| Component | Count | Location                            | Purpose               |
| --------- | ----- | ----------------------------------- | --------------------- |
| MON       | 3     | Smith, Trinity, Neo                 | Cluster state, quorum |
| MGR       | 3     | Co-located with MONs                | Dashboard, metrics    |
| OSD       | 4-6   | 2 on Smith, 1-2 each on Trinity/Neo | Storage daemons       |

### OSD Distribution

- Smith: 2 OSDs (4TB each, existing)
- Trinity: 2 OSDs (4TB each, new)
- Neo: 2 OSDs (4TB each, new)
- **Total: 6 OSDs, all same size**

Uniform OSD sizes ensure balanced CRUSH placement—data distributes evenly across all three nodes. No single node is more "important" for storage than another.

## How Ceph Solves the Problems

### RPO = 0

```
Write Path (Ceph):
  VM writes → Ceph writes to Smith + Trinity + Neo → Ceph confirms to VM
                         ↑
                    No gap possible

Write Path (Async Replication):
  VM writes to Smith → Smith confirms → (later) Smith syncs to Trinity
                                              ↑
                                         15-min gap
```

Every write hits multiple nodes before the VM gets confirmation. No replication lag.

### Automatic Recovery

| Scenario          | Behavior                                       |
| ----------------- | ---------------------------------------------- |
| Smith OSD dies    | Ceph rebalances to Trinity + Neo               |
| Smith node dies   | VMs restart on Trinity/Neo, data already there |
| Network partition | Quorum decides who's authoritative             |

No Keepalived, no manual promotion, no split-brain decisions.

### No RAID0 Risk

RAID0 is eliminated. Each piece of data exists on 3 nodes. Single drive failure = Ceph heals itself.

## Failure Modes

| Failure              | Ceph Tier                        | Local Tier              | Cold Tier            |
| -------------------- | -------------------------------- | ----------------------- | -------------------- |
| Smith node dies      | ✅ VMs continue on Trinity/Neo   | ✅ Not affected         | ❌ PBS/media offline |
| Trinity node dies    | ✅ VMs continue on Smith/Neo     | ⚠️ Oracle VMs fail over | N/A                  |
| Neo node dies        | ✅ VMs continue on Smith/Trinity | ⚠️ GPU workstation down | N/A                  |
| 2 nodes die          | ❌ Ceph loses quorum             | ⚠️ Depends which nodes  | Depends              |
| All 3 Ceph nodes die | ❌ Total loss                    | ✅ Local VMs survive    | ❌ Cold offline      |

**Key insight:** Local tier (router, auth, PKI, monitoring) survives Ceph failure.

## Migration Plan

### Phase 1: Hardware Procurement

| Item                    | Est. Cost     |
| ----------------------- | ------------- |
| 2x 4TB NVMe for Trinity | ~$800         |
| 2x 4TB NVMe for Neo     | ~$800         |
| **Total**               | **~$1600** 😭 |

### Phase 2: Prepare Nodes

1. Convert Oracle to local-zfs (for critical infra replication) — see `proxmox-ha.md`
2. Convert Niobe to local-zfs (for monitoring)
3. Install new NVMe in Trinity and Neo
4. Verify 10Gbps connectivity between Smith, Trinity, Neo

### Phase 3: Deploy Ceph

1. Initialize Ceph cluster via Proxmox Datacenter → Ceph
2. Create MONs on Smith, Trinity, Neo
3. Create OSDs on all NVMe drives
4. Create pool: `vm-disks` with 3x replication
5. Add Ceph storage to Proxmox

### Phase 4: Migrate VMs to Ceph

```bash
# For each Ceph-tier VM:
qm migrate <vmid> <node> --with-local-disks --target-storage ceph-vm-disks
```

### Phase 5: Decommission NFS (for VM disks)

1. Verify all Ceph-tier VMs migrated
2. Remove NFS storage from Proxmox (for VM disks only)
3. Repurpose Smith's NVMe pool for Ceph OSDs
4. Keep NFS for bulk data (media, personal) if desired, or migrate to SeaweedFS

### Phase 6: Enable Proxmox HA

With Ceph as shared storage, Proxmox HA works natively:

```hcl
resource "proxmox_virtual_environment_hagroup" "ceph_workloads" {
  group      = "ceph-workloads"
  nodes      = ["smith", "trinity", "neo"]
  restricted = true
}

resource "proxmox_virtual_environment_haresource" "gitlab" {
  resource_id = "vm:1006"
  state       = "started"
  group       = proxmox_virtual_environment_hagroup.ceph_workloads.group
}
# Repeat for all Ceph-tier VMs
```

## Operational Considerations

### Day-to-Day Commands

```bash
# Check cluster health
ceph status
ceph health detail

# Add new OSD
ceph-volume lvm create --data /dev/nvme1n1

# Check OSD status
ceph osd tree

# Check pool usage
ceph df
```

### Monitoring Integration

- Ceph exports Prometheus metrics natively
- Add to existing monitoring stack
- Alert on: OSD down, PG degraded, nearfull, health warnings

### Maintenance Windows

- OSDs can be taken offline one at a time for maintenance
- Ceph rebalances automatically
- Set `noout` flag during planned maintenance to prevent rebalancing

## Comparison: Ceph vs Async Replication

| Aspect              | Ceph                                  | Async Replication (syncoid)                |
| ------------------- | ------------------------------------- | ------------------------------------------ |
| RPO                 | 0                                     | 15 min                                     |
| RTO                 | ~30 sec                               | ~15-30 min (manual) or ~2 min (Keepalived) |
| Split-brain risk    | None (quorum)                         | Possible                                   |
| Complexity          | Medium                                | Low                                        |
| Cost                | ~$1000 (4x 4TB NVMe)                  | ~$300-600 (one replica drive)              |
| Write latency       | Slightly higher (network round-trips) | Local speed                                |
| Recovery automation | Full                                  | Partial (Keepalived) or manual             |

## Costs Summary

| Item                 | One-Time   | Ongoing               |
| -------------------- | ---------- | --------------------- |
| NVMe drives (4x 4TB) | ~$1600     | -                     |
| Time investment      | ~4-8 hours | ~1 hr/month           |
| Capacity overhead    | -          | 50-66% for redundancy |

## Decision Factors

### Pros

- RPO=0 (no data loss on failover)
- Automatic, hands-off recovery
- Eliminates RAID0 risk completely
- Smith is no longer a single point of failure—storage is distributed equally
- Native Proxmox integration
- Scales horizontally (add more OSDs later)

### Cons

- ~$1000 upfront cost
- Slightly higher write latency
- Capacity overhead (3x replication = 33% usable)
- Another system to learn and maintain
- Overkill if 15-min RPO is acceptable

### When to Choose Ceph

- You can't afford 15-min data loss
- You want fully automated recovery
- You're comfortable with the complexity
- You have budget for drives

### When to Choose Async Replication

- 15-min RPO is acceptable
- Lower budget
- Prefer simpler architecture
- Already familiar with ZFS

## Open Questions

1. 3x replication vs erasure coding (2+1)? Replication is simpler, EC saves space.
2. Should we include Oracle/Niobe small drives in Ceph, or keep them local-only?
3. Network: dedicated Ceph network or shared with VMs?
4. Ceph pool settings: PG count, autoscaling?

## Status

**Exploration phase.** Recommended as the long-term storage architecture. Requires hardware purchase before implementation.

## Related Documents

- `proxmox-ha.md` — HA for local-tier VMs (Oracle, Niobe)
- `../storage.md` — Current storage architecture
- `../backups.md` — 3-2-1 backup strategy (unchanged)
