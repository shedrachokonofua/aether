# Ceph Implementation Guide

Step-by-step manual implementation of Ceph distributed storage on Proxmox.

## Prerequisites

- Proxmox cluster with 3+ nodes
- NVMe drives for OSDs on each node
- 10Gbps network between nodes (recommended)

## Network Verification

### Test Connectivity

```bash
# Install iperf3 on all nodes
apt install -y iperf3

# On one node (server)
iperf3 -s

# From other nodes (client)
iperf3 -c <server-ip>
```

**Expected:** ~9.4 Gbps for 10Gbps links

### Known Limitations

| Path            | Speed   | Reason                            |
| --------------- | ------- | --------------------------------- |
| Trinity ↔ Neo   | 10 Gbps | Direct SFP+                       |
| Trinity ↔ Smith | 3 Gbps  | PCIe x1 bottleneck (B550 chipset) |
| Neo ↔ Smith     | 3 Gbps  | PCIe x1 bottleneck (B550 chipset) |

**Smith's 10G NIC runs at PCIe x1 due to B550 lane sharing with M.2 slots.**

Check PCIe link status:

```bash
lspci -vvs <nic-bus-id> | grep -E 'LnkCap|LnkSta'
# Look for "Width x1 (downgraded)"
```

**Impact:** ~7-8 Gbps average cluster speed (still 2.5x better than single 3Gbps NFS)

---

## Phase 1: Install Ceph Packages

On each node (smith, trinity, neo):

### Via Proxmox UI

1. Go to **Node → Ceph**
2. Click **Install Ceph**
3. Select:
   - Repository: **No-Subscription**
   - Version: **Reef** (or latest stable)
4. Wait for installation to complete

### Via CLI

```bash
pveceph install --repository no-subscription --version reef
```

---

## Phase 2: Initialize Cluster

**On first node only (e.g., trinity):**

### Via Proxmox UI

1. Go to **Node → Ceph → Configuration**
2. Click **Create Cluster**
3. Network: Use default (192.168.2.0/24) or set dedicated Ceph network
4. Click **Create**

### Via CLI

```bash
pveceph init --network 192.168.2.0/24
```

---

## Phase 3: Create Monitors (MON)

Create MON on each node for quorum (need 3 for HA):

### Via Proxmox UI

1. Go to **Node → Ceph → Monitor**
2. Click **Create**
3. Repeat on all 3 nodes

### Via CLI

```bash
# On each node
pveceph mon create
```

### Verify

```bash
ceph mon stat
# Should show: 3 mons at {neo,smith,trinity}
```

---

## Phase 4: Create OSDs

### Via Proxmox UI

1. Go to **Node → Ceph → OSD**
2. Click **Create: OSD**
3. Select NVMe drive (e.g., `/dev/nvme0n1`)
4. Click **Create**
5. Repeat for each NVMe drive on each node

### Via CLI

```bash
# List available drives
pveceph osd create /dev/nvme0n1
pveceph osd create /dev/nvme1n1
```

### Verify

```bash
ceph osd tree
# Should show all OSDs organized by host
```

**Note:** If migrating from NFS, create OSDs on Trinity/Neo first. Add Smith OSDs after VMs are migrated off NFS.

---

## Phase 5: Create Pool

### Via Proxmox UI

1. Go to **Datacenter → Ceph → Pools**
2. Click **Create**
3. Settings:
   - Name: `vm-disks`
   - Size: `3` (3x replication)
   - Min Size: `2`
   - PG Autoscale: `on`
4. Click **Create**

### Via CLI

```bash
ceph osd pool create vm-disks 64 64 replicated
ceph osd pool set vm-disks size 3
ceph osd pool set vm-disks min_size 2
ceph osd pool application enable vm-disks rbd
```

### Verify

```bash
ceph osd pool ls detail
```

---

## Phase 6: Add RBD Storage to Proxmox

### Via Proxmox UI

1. Go to **Datacenter → Storage → Add → RBD**
2. Settings:
   - ID: `ceph-vm-disks`
   - Pool: `vm-disks`
   - Monitor(s): `192.168.2.202,192.168.2.204,192.168.2.205`
   - Content: `Disk image, Container`
3. Click **Add**

### Via CLI (if needed)

Edit `/etc/pve/storage.cfg`:

```
rbd: ceph-vm-disks
    content images,rootdir
    krbd 0
    monhost 192.168.2.202,192.168.2.204,192.168.2.205
    pool vm-disks
    username admin
```

Create keyring file if missing:

```bash
cat > /etc/pve/priv/ceph/ceph-vm-disks.keyring << EOF
[client.admin]
    key = $(ceph auth get client.admin | grep key | awk '{print $3}')
EOF
chmod 600 /etc/pve/priv/ceph/ceph-vm-disks.keyring
```

### Verify

```bash
pvesm status | grep ceph
# Should show: ceph-vm-disks    rbd    active
```

---

## Phase 7: Migrate VMs to Ceph

### Via Proxmox UI

1. Select VM → **Hardware**
2. Select disk (e.g., `virtio0`)
3. Click **Disk Action → Move Storage**
4. Target Storage: `ceph-vm-disks`
5. Check **Delete source**
6. Click **Move disk**

### Via CLI

```bash
# Move disk
qm move_disk <vmid> virtio0 ceph-vm-disks --delete

# For LXC containers
pct move_volume <vmid> rootfs ceph-vm-disks --delete
```

### VMs to Migrate

| VMID | Name            | Size  | Status |
| ---- | --------------- | ----- | ------ |
| 1005 | dokploy         | 256GB | ✅     |
| 1006 | gitlab          | 128GB | ✅     |
| 1009 | iot-management  | 32GB  | ✅     |
| 1010 | dev-workstation | 256GB | ✅     |
| 1011 | lute            | 256GB | ✅     |
| 1014 | game-server     | 256GB | ✅     |
| 1015 | cockpit         | 32GB  | ✅     |
| 1016 | messaging-stack | 64GB  | ✅     |
| 1018 | ai-tool-stack   | 128GB | ✅     |
| 1019 | ups-management  | 32GB  | ✅     |
| 1020 | media-stack     | 128GB | ✅     |
| 1021 | dokku           | 256GB | ✅     |
| 1024 | smallweb        | 16GB  | ✅     |

### VMs NOT on Ceph (by design)

| VMID | Name             | Storage         | Reason                          |
| ---- | ---------------- | --------------- | ------------------------------- |
| 1001 | vyos-router      | Oracle local    | Critical infrastructure         |
| 1002 | gateway-stack    | Oracle local    | Critical infrastructure         |
| 1003 | monitoring-stack | Niobe local     | Must alert when Ceph is down    |
| 1007 | backup-stack     | Smith local-lvm | Backups must work if Ceph fails |
| 1017 | gpu-workstation  | Neo local       | GPU passthrough, can't HA       |
| 1023 | keycloak         | Oracle local    | Critical infrastructure         |
| 1025 | step-ca          | Oracle local    | Critical infrastructure         |
| 1026 | openbao          | Oracle local    | Critical infrastructure         |

---

## Phase 8: Add Smith OSDs

After VMs are migrated off NFS, free Smith's NVMe for Ceph:

### 1. Move data off NVMe

```bash
# Move personal/data to HDD
rsync -av /mnt/nvme/personal/ /mnt/hdd/personal/
rsync -av /mnt/nvme/data/ /mnt/hdd/data/
```

### 2. Move PBS LXC to local-lvm

Via Proxmox UI: 1007 → Hardware → rootfs → Move Storage → `local-lvm`

### 3. Shut down NFS LXC

```bash
pct stop 1004
pct destroy 1004
```

### 4. Destroy NVMe ZFS pool

```bash
zpool destroy nvme
```

### 5. Add NVMe drives as Ceph OSDs

```bash
pveceph osd create /dev/nvme0n1
pveceph osd create /dev/nvme1n1
```

### 6. Verify health

```bash
ceph status
# Should show HEALTH_OK with all OSDs
```

---

## Phase 9: CephFS for Hot Data

**Required** — Replaces `/mnt/nvme/data` for hot projects and file-level access:

### Create MDS (Metadata Server)

Via Proxmox UI: **Node → Ceph → CephFS → Create MDS**

Or via CLI on each node:

```bash
pveceph mds create
```

### Create CephFS

```bash
# Create pools
ceph osd pool create cephfs_data 64
ceph osd pool create cephfs_metadata 32

# Create filesystem
ceph fs new cephfs cephfs_metadata cephfs_data
```

### Add to Proxmox Storage

**Datacenter → Storage → Add → CephFS**

- ID: `ceph-data`
- Monitor(s): `192.168.2.202,192.168.2.204,192.168.2.205`
- Content: `VZDump backup file, Container template, ISO image, Snippets`

### Mount in LXC/VM

```bash
# Install ceph client
apt install ceph-common

# Get admin key
ceph auth get client.admin

# Mount
mount -t ceph 192.168.2.202,192.168.2.204,192.168.2.205:/ /mnt/cephfs \
  -o name=admin,secret=<key>
```

---

## Phase 10: Network Bonding (Optional Enhancement)

If Smith has multiple NICs, bond them for more bandwidth:

### Edit /etc/network/interfaces

```bash
auto lo
iface lo inet loopback

iface enp5s0 inet manual

iface enp8s0 inet manual

auto bond0
iface bond0 inet manual
    bond-slaves enp5s0 enp8s0
    bond-mode balance-alb
    bond-miimon 100

auto vmbr0
iface vmbr0 inet static
    address 192.168.2.204/24
    gateway 192.168.2.1
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
```

### Apply

```bash
# Reboot (safest)
reboot

# Or live reload (riskier)
ifreload -a
```

**Result:** Smith goes from ~3Gbps to ~5.5Gbps (10G + 2.5G bonded)

---

## Verification Commands

### Cluster Health

```bash
ceph status
ceph health detail
```

### OSD Status

```bash
ceph osd tree
ceph osd df
```

### Pool Usage

```bash
ceph df
rados df
```

### RBD Images

```bash
rbd -p vm-disks ls
rbd -p vm-disks info <image-name>
```

### I/O Stats

```bash
ceph status  # Shows io: section
ceph osd perf
```

---

## Troubleshooting

### Storage shows "inactive"

Check keyring file:

```bash
cat /etc/pve/priv/ceph/ceph-vm-disks.keyring
# Should have [client.admin] and key
```

Check monhost uses IPs not hostnames:

```bash
grep monhost /etc/pve/storage.cfg
# Should be: monhost 192.168.2.202,192.168.2.204,192.168.2.205
```

### HEALTH_WARN degraded

With only 2 nodes, 3x replication can't be satisfied. Add third node's OSDs.

```bash
ceph health detail
# Shows which PGs are undersized
```

### Slow performance

Check network:

```bash
iperf3 -c <other-node>
```

Check PCIe:

```bash
lspci -vvs <nic-bus-id> | grep LnkSta
```

Check OSD performance:

```bash
ceph osd perf
```

---

## Maintenance

### Set noout before maintenance

```bash
ceph osd set noout
# Do maintenance
ceph osd unset noout
```

### Restart OSD

```bash
systemctl restart ceph-osd@<id>
```

### Check rebalancing

```bash
ceph -w  # Watch mode
```

---

## Update Terraform

After migration, update TF files:

```bash
cd tofu/home
sed -i 's/nfs-nvme-vm-dataset/ceph-vm-disks/g' *.tf
tofu plan  # Should show no changes
```

---

## Current Status

| Component               | Status                                |
| ----------------------- | ------------------------------------- |
| Ceph packages installed | ✅                                    |
| MONs created (3)        | ✅                                    |
| OSDs on Trinity/Neo (4) | ✅                                    |
| Pool `vm-disks` created | ✅                                    |
| RBD storage added       | ✅                                    |
| VMs migrated            | ✅                                    |
| Smith OSDs              | ⏳ Pending                            |
| CephFS for hot data     | ⏳ Required — replaces /mnt/nvme/data |
| Smith bonding           | ⏳ Optional                           |
| Proxmox HA enabled      | ⏳ Pending                            |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     CEPH CLUSTER                            │
│                                                             │
│   Trinity (10Gbps)    Neo (10Gbps)      Smith (3Gbps)*     │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    │
│   │ MON │ MGR   │    │ MON │ MGR   │    │ MON │ MGR   │    │
│   ├─────────────┤    ├─────────────┤    ├─────────────┤    │
│   │ OSD (4TB)   │    │ OSD (4TB)   │    │ OSD (4TB)   │    │
│   │ OSD (4TB)   │    │ OSD (4TB)   │    │ OSD (4TB)   │    │
│   └─────────────┘    └─────────────┘    └─────────────┘    │
│         │                  │                  │            │
│         └──────────────────┼──────────────────┘            │
│                            │                               │
│                    vm-disks pool                           │
│                    (3x replication)                        │
│                    ~5TB usable → ~8TB with Smith           │
└─────────────────────────────────────────────────────────────┘

* Smith limited by PCIe x1 (B550 M.2 lane sharing)
```
