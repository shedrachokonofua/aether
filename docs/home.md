# Home

## Hosts

| Host    | RAM   | Storage                             | CPU                  | GPU                      | Cores | Threads | vCPUs | Network | Model             | Gigahub IP    |
| ------- | ----- | ----------------------------------- | -------------------- | ------------------------ | ----- | ------- | ----- | ------- | ----------------- | ------------- |
| Niobe   | 64GB  | 1TB NVME, 512GB MVME                | AMD Ryzen 9 6900HX   | AMD Radeon 680M          | 8     | 16      | 16    | 2.5Gbps | Beelink Ser6 Max  | 192.168.2.201 |
| Trinity | 64GB  | 1TB NVME                            | Intel Core i9-13900H | Intel Iris Xe            | 14    | 20      | 20    | 10Gbps  | Minisforum MS-01  | 192.168.2.202 |
| Oracle  | 16GB  | 1TB NVME                            | Intel Core i5-12600H | Intel Iris Xe            | 12    | 16      | 16    | 10Gbps  | Minisforum MS-01  | 192.168.2.203 |
| Smith   | 128GB | 8TB NVME(4TB x2), 56TB HDD(14TB x4) | AMD Ryzen 7 3700X    | Nvidia RTX 1660 Super    | 8     | 16      | 16    | 10Gbps  | Custom            | 192.168.2.204 |
| Neo     | 128GB | 2TB NVME                            | AMD Ryzen 9 9950X3D  | Nvidia RTX Pro 6000 MaxQ | 16    | 32      | 32    | 10Gbps  | Custom            | 192.168.2.205 |

## Network

### WAN

Assigned by Bell Gigahub via PPPoE. 3Gbps up/down.

### LAN

Bell Gigahub LAN Base: 192.168.2.0/24
VyOS LAN Base: 10.0.0.0/16

#### VLANs

| VLAN | Name          | Subnet         | Gateway     | DHCP Range | Description                                                                |
| ---- | ------------- | -------------- | ----------- | ---------- | -------------------------------------------------------------------------- |
| 2    | Control Plane | 192.168.2.0/24 | 192.168.2.1 | Static     | Isolated network between ISP modem and rack mounted hardware               |
| 3    | Rack          | 10.0.3.0/24    | 10.0.3.1    | 240 - 254  | Infrastructure network for virtual machines                                |
| 4    | Personal      | 10.0.4.0/24    | 10.0.4.1    | 2 - 254    | Primary network for trusted devices with full management access            |
| 5    | Media         | 10.0.5.0/24    | 10.0.5.1    | 2 - 254    | Home entertainment devices with access to internet and local media servers |
| 6    | IoT           | 10.0.6.0/24    | 10.0.6.1    | 2 - 254    | Home IoT devices with access to internet and local home automation servers |
| 7    | Guest         | 10.0.7.0/24    | 10.0.7.1    | 2 - 254    | Guest network with internet access                                         |

#### Rack Switch

**Device Name**: QNAP QSW-M3216R-8S8T-US

**Specs**:

- 8x 10Gbps Ethernet ports
- 8x 10Gbps SFP+ ports

| Port | Type     | Device                                                | VLAN tags        | Speed   |
| ---- | -------- | ----------------------------------------------------- | ---------------- | ------- |
| 1    | Ethernet | Bell Gigahub                                          | 2                | 10Gbps  |
| 2    | Ethernet | Access Point                                          | 4, 5, 6, 7       | 2.5Gbps |
| 3    | Ethernet | Niobe                                                 | 2, 3, 4, 5, 6, 7 | 2.5Gbps |
| 4    | Ethernet | UPS                                                   | 2                | 100Mbps |
| 5    | Ethernet | Office Switch                                         | 2, 3, 4, 5       | 2.5Gbps |
| 6    | Ethernet | PiKVM                                                 | 2                | 1Gbps   |
| 7    | Ethernet | MoCA Adapter (Uplink to unmanaged living room switch) | 5                | 2.5Gbps |
| 10   | SFP+     | Trinity                                               | 2, 3, 4, 5, 6, 7 | 10Gbps  |
| 11   | SFP+     | Smith                                                 | 2, 3, 4, 5, 6, 7 | 10Gbps  |

#### Office Switch

**Device Name**: Nicgiga 8-Port 2.5Gbps Switch 10Gbps SFP Uplink

**Specs**:

- 1x 10Gbps SFP+ port
- 8x 2.5Gbps Ethernet ports

| Port | Type     | Device             | VLAN tags  | Speed   |
| ---- | -------- | ------------------ | ---------- | ------- |
| 1    | Ethernet | Google TV Streamer | 5          | 1Gbps   |
| 2    | Ethernet | Raspberry Pi 5     | 4          | 1Gbps   |
| 3    | Ethernet | Laptop Dock        | 4          | 2.5Gbps |
| 4    | Ethernet | Raspberry Pi 5     | 4          | 1Gbps   |
| 9    | SFP+     | Rack Switch        | 2, 3, 4, 5 | 10Gbps  |

#### Access Point

**Device Name**: Ubiquiti Unifi U7 Pro

**Specs**:

- 2.5Gbps PoE+

| SSID         | VLAN |
| ------------ | ---- |
| Ruby Nexus   | 4    |
| Sienna Helix | 5    |
| Indigo Tide  | 6    |
| Moss Cove    | 7    |

## Storage

Smith is the designated shared storage node in the home cluster. It's running ZFS with an array consisting of:

| Count | Type | Size | RAID   | Total(Raw) | Total(Usable) |
| ----- | ---- | ---- | ------ | ---------- | ------------- |
| 2     | NVME | 4TB  | RAID0  | 8TB        | 8TB           |
| 4     | HDD  | 14TB | RAID10 | 56TB       | 28TB          |

### Pools

| Pool | Description |
| ---- | ----------- |
| nvme | NVMe drives |
| hdd  | HDD drives  |

### Datasets

| Name             | Mountpoint            | Compression | Record Size | Description                                      |
| ---------------- | --------------------- | ----------- | ----------- | ------------------------------------------------ |
| nvme/personal    | /mnt/nvme/personal    | lz4         | default     | Personal data storage, backed up to google drive |
| nvme/vm          | /mnt/nvme/vm          | lz4         | 16K         | Performance-optimized storage for VMs            |
| nvme/data        | /mnt/nvme/data        | lz4         | default     | Performance-optimized storage for generic data   |
| hdd/vm           | /mnt/hdd/vm           | lz4         | default     | Capacity-optimized storage for VMs               |
| hdd/data         | /mnt/hdd/data         | lz4         | default     | Capacity-optimized storage for generic data      |
| hdd/backups-vm   | /mnt/hdd/backups-vm   | lz4         | default     | VM backups                                       |
| hdd/backups-data | /mnt/hdd/backups-data | lz4         | default     | Generic data backups                             |

### Network File System

Smith hosts an NFS server that serves as a storage backend for the home proxmox cluster.

#### NFS Exports

- /mnt/nvme/vm
- /mnt/hdd/vm

### SMB/CIFS

Smith also hosts a Samba server for sharing files within the home network.

#### SMB/CIFS Exports

- /mnt/nvme/personal
- /mnt/nvme/data
- /mnt/hdd/data

### Backups

Layered approach (snapshots, local backups/replicas, offsite S3) following the 3-2-1 rule.

#### ZFS Snapshots

| Dataset          | Frequency      | Retention                        |
| ---------------- | -------------- | -------------------------------- |
| nvme/personal    | Hourly         | Hourly: 12, Daily: 7, Weekly: 4  |
| nvme/vm          | Hourly         | Hourly: 12, Daily: 7, Weekly: 4  |
| nvme/data        | Hourly         | Hourly: 12, Daily: 7, Weekly: 4  |
| hdd/vm           | Daily @ 1:30AM | Daily: 14, Weekly: 8, Monthly: 6 |
| hdd/data         | Daily @ 1:30AM | Daily: 14, Weekly: 8, Monthly: 6 |
| hdd/backups-vm   | Daily @ 2:00AM | Daily: 7                         |
| hdd/backups-data | Daily @ 2:00AM | Daily: 7                         |

#### Proxmox Backup Server

Handles local, deduplicated backups for VMs and LXCs on the proxmox cluster.

| Frequency   | Retention                                  |
| ----------- | ------------------------------------------ |
| Daily @ 2AM | Daily: 7, Weekly: 4, Monthly: 6, Yearly: 2 |

#### Local Replication

| Source Dataset | Target Dataset            | Frequency      |
| -------------- | ------------------------- | -------------- |
| nvme/personal  | hdd/backups-data/personal | Daily @ 2:30AM |
| nvme/data      | hdd/backups-data/data     | Daily @ 2:30AM |

#### Offsite Backups

| Source Dataset   | Target       | Frequency   |
| ---------------- | ------------ | ----------- |
| hdd/data         | S3           | Daily @ 3AM |
| hdd/backups-vm   | S3           | Daily @ 3AM |
| hdd/backups-data | S3           | Daily @ 3AM |
| nvme/personal    | Google Drive | Live        |
