# Home

## Network

### WAN

Assigned by Bell Gigahub via PPPoE

### LAN

Bell Gigahub LAN Base: 192.168.2.0/24
VyOS LAN Base: 10.0.0.0/16

#### VLANs

| VLAN | Name     | Subnet       | Gateway   | DHCP Range      | Description                                                                                          |
| ---- | -------- | ------------ | --------- | --------------- | ---------------------------------------------------------------------------------------------------- |
| 10   | WAN      | 10.0.10.0/24 | 10.0.10.1 | N/A - Static    | Isolated network between ISP modem and Proxmox cluster                                               |
| 20   | Personal | 10.0.20.0/24 | 10.0.20.1 | 10.0.20.2-254   | Primary network for trusted devices with full management access                                      |
| 30   | Media    | 10.0.30.0/24 | 10.0.30.1 | 10.0.30.2-254   | Home entertainment devices with access to internet and local media servers                           |
| 40   | IoT      | 10.0.40.0/24 | 10.0.40.1 | 10.0.40.2-254   | Home IoT devices with access to internet and local home automation servers                           |
| 50   | Guest    | 10.0.50.0/24 | 10.0.50.1 | 10.0.50.2-254   | Guest network with internet access                                                                   |
| 60   | Rack     | 10.0.60.0/24 | 10.0.60.1 | 10.0.60.200-254 | Infrastructure network for rack-mounted hardware(10.0.60.2-99) and virtual machines(10.0.60.100-199) |

#### Rack Switch

**Device Name**: QNAP QSW-M3216R-8S8T-US

**Specs**:

- 8x 10Gbps Ethernet ports
- 8x 10Gbps SFP+ ports

| Port | Type     | Device                                                | VLAN tags              | Speed                 |
| ---- | -------- | ----------------------------------------------------- | ---------------------- | --------------------- |
| 1    | Ethernet | Bell Gigahub                                          | 10                     | 10Gbps (3Gbps Uplink) |
| 2    | Ethernet | Access Point                                          | 20, 30, 40, 50         | 2.5Gbps               |
| 3    | Ethernet | Niobe                                                 | 10, 20, 30, 40, 50, 60 | 2.5Gbps               |
| 4    | Ethernet | UPS                                                   | 60                     | 100Mbps               |
| 5    | Ethernet | Office Switch                                         | 10, 20, 30, 50         | 2.5Gbps               |
| 6    | Ethernet | PiKVM                                                 | 60                     | 1Gbps                 |
| 7    | Ethernet | MoCA Adapter (Uplink to unmanaged living room switch) | 30                     | 2.5Gbps               |
| 10   | SFP+     | Trinity                                               | 10, 20, 30, 40, 50, 60 | 10Gbps                |
| 11   | SFP+     | Smith                                                 | 10, 20, 30, 40, 50, 60 | 10Gbps                |

#### Office Switch

**Device Name**:

**Specs**:

- 1x 10Gbps SFP+ port
- 8x 2.5Gbps Ethernet ports

| Port | Type     | Device             | VLAN tags      | Speed   |
| ---- | -------- | ------------------ | -------------- | ------- |
| 1    | Ethernet | Raspberry Pi 5     | 20             | 1Gbps   |
| 2    | Ethernet | Laptop Dock        | 20             | 2.5Gbps |
| 3    | Ethernet | Raspberry Pi 5     | 20             | 1Gbps   |
| 4    | Ethernet | Google TV Streamer | 30             | 1Gbps   |
| 5    | Ethernet | Management Port    | 10, 20, 30, 50 | 2.5Gbps |
| 9    | SFP+     | Rack Switch        | 10, 20, 30, 50 | 10Gbps  |

**Note**: Work Laptop should be pinned to VLAN 50 on the office switch by MAC address.

#### Access Point

**Device Name**: Ubiquiti Unifi U7 Pro

**Specs**:

- 2.5Gbps PoE+

| SSID         | VLAN |
| ------------ | ---- |
| Ruby Nexus   | 20   |
| Sienna Helix | 30   |
| Indigo Tide  | 40   |
| Moss Cove    | 50   |

### Hosts

| Host    | RAM   | Storage                             | CPU                  | GPU                   | Cores | Threads | vCPUs | Network | Model            | Gigahub IP    | VyOS IP   |
| ------- | ----- | ----------------------------------- | -------------------- | --------------------- | ----- | ------- | ----- | ------- | ---------------- | ------------- | --------- |
| Niobe   | 64GB  | 1TB NVME, 512GB MVME                | AMD Ryzen 9 6900HX   | AMD Radeon 680M       | 8     | 16      | 16    | 2.5Gbps | Beelink Ser6 Max | 192.168.2.201 | 10.0.60.2 |
| Trinity | 64GB  | 1TB NVME                            | Intel Core i9-13900H | Intel Iris Xe         | 14    | 20      | 20    | 10Gbps  | Minisforum MS-01 | 192.168.2.202 | 10.0.60.3 |
| Smith   | 128GB | 8TB NVME(4TB x2), 56TB HDD(14TB x4) | AMD Ryzen 7 3700X    | Nvidia RTX 1660 Super | 8     | 16      | 16    | 10Gbps  | Custom           | 192.168.2.203 | 10.0.60.4 |
