# Hosts

Five Proxmox VE hosts form the home compute cluster. All hosts run Proxmox VE and are members of a unified cluster for VM/LXC migration and shared storage.

| Host    | RAM   | Storage                             | CPU                  | GPU                      | Cores | Threads | vCPUs | Network | Model            | Gigahub IP    |
| ------- | ----- | ----------------------------------- | -------------------- | ------------------------ | ----- | ------- | ----- | ------- | ---------------- | ------------- |
| Niobe   | 64GB  | 512GB MVME                          | AMD Ryzen 9 6900HX   | AMD Radeon 680M          | 8     | 16      | 16    | 2.5Gbps | Beelink Ser6 Max | 192.168.2.201 |
| Trinity | 64GB  | 1TB NVME                            | Intel Core i9-13900H | Intel Iris Xe            | 14    | 20      | 20    | 10Gbps  | Minisforum MS-01 | 192.168.2.202 |
| Oracle  | 16GB  | 1TB NVME                            | Intel Core i5-12600H | Intel Iris Xe            | 12    | 16      | 16    | 10Gbps  | Minisforum MS-01 | 192.168.2.203 |
| Smith   | 128GB | 8TB NVME(4TB x2), 56TB HDD(14TB x4) | AMD Ryzen 7 3700X    | Nvidia RTX 1660 Super    | 8     | 16      | 16    | 10Gbps  | Custom           | 192.168.2.204 |
| Neo     | 128GB | 2TB NVME                            | AMD Ryzen 9 9950X    | Nvidia RTX Pro 6000 MaxQ | 16    | 32      | 32    | 10Gbps  | Custom           | 192.168.2.205 |

## Host Roles

### Oracle

Core infrastructure host. Runs essential services that must remain stable and always-on:

- VyOS Router
- Home Gateway Stack (Caddy, AdGuard, Tailscale, UniFi)
- Keycloak (Identity Provider)
- step-ca (Certificate Authority)
- OpenBao (Secrets Management)

### Smith

Storage and backup host. Houses all shared storage arrays and backup infrastructure:

- Network File Server (NFS/SMB)
- Proxmox Backup Server
- SeaweedFS (Object Storage)
- Lute Stack
- Gaming Server (GPU passthrough)

### Neo

GPU compute host. Dedicated to AI/ML workloads with high-end GPU:

- GPU Workstation (Ollama, ComfyUI, JupyterLab, SwarmUI, ClearML, Docling)
- AI Tool Stack (LiteLLM, SearXNG, Firecrawl, OpenWebUI)
- Dokku (PaaS)

### Trinity

Application host. Runs general-purpose application workloads:

- Development Workstation
- GitLab
- Dokploy
- Media Stack
- Smallweb

### Niobe

Lightweight services host. Runs low-resource services and monitoring:

- Monitoring Stack
- IoT Management Stack
- UPS Management Stack
- Messaging Stack
- Cockpit
- Coupe Sandbox
