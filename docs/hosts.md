# Hosts

Physical host inventory for the lab. This page tracks machines and boards, not VM placements.

Host count: 9 physical systems: 5 x86 Proxmox hosts and 4 ARM Talos boards.

## Inventory

| Host           | Type         | OS          | Physical role      | RAM   | Storage                               | CPU / SoC            | GPU                      | Cores / Threads | Network | Model / Board       | Primary IP    |
| -------------- | ------------ | ----------- | ------------------ | ----- | ------------------------------------- | -------------------- | ------------------------ | --------------- | ------- | ------------------- | ------------- |
| `niobe`        | x86 host     | Proxmox VE  | Compute            | 64GB  | 512GB NVME                            | AMD Ryzen 9 6900HX   | AMD Radeon 680M          | 8 / 16          | 2.5Gbps | Beelink SER6 Max    | 192.168.2.201 |
| `trinity`      | x86 host     | Proxmox VE  | Compute            | 64GB  | 9TB NVME (4TB x2 + 1TB boot)          | Intel Core i9-13900H | Intel Iris Xe            | 14 / 20         | 10Gbps  | Minisforum MS-01    | 192.168.2.202 |
| `oracle`       | x86 host     | Proxmox VE  | Core infra / edge  | 16GB  | 1TB NVME                              | Intel Core i5-12600H | Intel Iris Xe            | 12 / 16         | 10Gbps  | Minisforum MS-01    | 192.168.2.203 |
| `smith`        | x86 host     | Proxmox VE  | Storage / GPU      | 128GB | 8TB NVME (4TB x2), 56TB HDD (14TB x4) | AMD Ryzen 7 3700X    | Nvidia RTX 1660 Super    | 8 / 16          | 10Gbps  | Custom              | 192.168.2.204 |
| `neo`          | x86 host     | Proxmox VE  | GPU compute        | 128GB | 10TB NVME (4TB x2 + 2TB boot)         | AMD Ryzen 9 9950X    | Nvidia RTX Pro 6000 MaxQ | 16 / 32         | 10Gbps  | Custom              | 192.168.2.205 |
| `talos-tank`   | ARM board    | Talos Linux | Kubernetes worker  | 4GB   | microSD                               | Raspberry Pi 5       | VideoCore VII            | 4 / 4           | 1Gbps   | Raspberry Pi 5      | 10.0.3.23     |
| `talos-dozer`  | ARM board    | Talos Linux | Kubernetes worker  | 4GB   | microSD                               | Raspberry Pi 5       | VideoCore VII            | 4 / 4           | 1Gbps   | Raspberry Pi 5      | 10.0.3.24     |
| `talos-mouse`  | ARM board    | Talos Linux | Kubernetes worker  | 4GB   | microSD                               | Raspberry Pi 4       | VideoCore VI             | 4 / 4           | 1Gbps   | Raspberry Pi 4      | 10.0.3.25     |
| `talos-sparks` | ARM board    | Talos Linux | Kubernetes worker  | 4GB   | microSD                               | Raspberry Pi CM4     | VideoCore VI             | 4 / 4           | 1Gbps   | CM4 Lite / Mini Base | 10.0.3.26     |

## Notes

- The five x86 hosts are Proxmox VE cluster members.
- `oracle` is the physical home for edge and core infrastructure workloads.
- `smith` provides bulk storage and the RTX 1660 Super GPU.
- `neo` provides the RTX Pro 6000 Blackwell GPU used by the Kubernetes GPU node.
- The four ARM boards are bare-metal Talos Kubernetes workers on VLAN 3.
- VM and application placement lives in `config/vm.yml`; Kubernetes platform details live in `docs/paas.md` and the Talos exploration docs.
