# Blueprint

## Home

### Available Resources

| Host    | RAM   | Storage                              | CPU                  | GPU                       | Cores | Threads | vCPUs | Ethernet | Status |
| ------- | ----- | ------------------------------------ | -------------------- | ------------------------- | ----- | ------- | ----- | -------- | ------ |
| Oracle  | 16GB  | 1TB                                  | Intel Core i5-12600H | Intel Iris Xe             | 12    | 16      | 16    | 10G      | LIVE   |
| Smith   | 128GB | 8TB NVME(4TB x2) + 56TB HDD(14TB x4) | AMD Ryzen 7 3700X    | Nvidia RTX 1660 Super     | 8     | 16      | 16    | 10G      | LIVE   |
| Niobe   | 64GB  | 512GB                                | AMD Ryzen 9 6900HX   | AMD Radeon 680M           | 8     | 16      | 16    | 2.5G     | LIVE   |
| Neo     | 128GB | 2TB                                  | AMD Rzyen 9 9950X    | Nvidia RTX Pro 6000 Max-Q | 16    | 32      | 32    | 10G      | LIVE   |
| Trinity | 64GB  | 1TB                                  | Intel Core i9-13900H | Intel Iris Xe             | 14    | 20      | 20    | 10G      | LIVE   |

### Resource Allocation

| Name                    | Host    | Type | RAM  | Storage            | Storage Location | vCPU | GPU         | On By Default | Notes                                                                                           | Status      |
| ----------------------- | ------- | ---- | ---- | ------------------ | ---------------- | ---- | ----------- | ------------- | ----------------------------------------------------------------------------------------------- | ----------- |
| Router                  | Oracle  | VM   | 4GB  | 128GB              | Node             | 8    | None        | Yes           | VyOs                                                                                            | LIVE        |
| Gateway Stack           | Oracle  | VM   | 4GB  | 128GB              | Node             | 8    | None        | Yes           | UniFi Network Server, Caddy, AdGuard, Tailscale subnet router                                   | LIVE        |
| Development Workstation | Trinity | VM   | 16GB | 256GB              | Node             | 8    | None        | Yes           | Coder Server                                                                                    | LIVE        |
| Gaming Server           | Smith   | VM   | 16GB | 256GB              | Node - NVME      | 12   | Passthrough | No            | Bazzite VM: Steam, PS, PS2, PS3 simulation                                                      | LIVE        |
| GPU Workstation         | Neo     | VM   | 64GB | 1TB                | Node             | 32   | Passthrough | Yes           | Ollama + Models, Docling, ComfyUI, JupyterLab, SwarmUI                                          | LIVE        |
| AI Tool Stack           | Neo     | VM   | 8GB  | 128GB              | NFS - NVME       | 4    | None        | Yes           | LiteLLM, SearXNG, Firecrawl, OpenWebUI, LibreChat, MetaMCP, Bytebot                             | LIVE        |
| Monitoring Stack        | Niobe   | VM   | 4GB  | 128GB              | Node             | 4    | None        | Yes           | Otel Collector, Prometheus, Grafana, Tempo, Loki, Promtail, Pyroscope                           | LIVE        |
| Gitlab                  | Trinity | VM   | 8GB  | 128GB              | NFS - NVME       | 8    | None        | Yes           | VCS, CI/CD, Package Registry                                                                    | LIVE        |
| Lute Stack              | Smith   | VM   | 40GB | 256GB              | NFS - NVME       | 8    | None        | Yes           | Lute, Redis, Minio, Neo4j                                                                       | LIVE        |
| Coupe Sandbox           | Niobe   | VM   | 4GB  | 64GB               | NFS - NVME       | 4    | None        | Yes           | Deployment server for coupe projects                                                            | LIVE        |
| IoT Management Stack    | Niobe   | VM   | 2GB  | 32GB               | NFS - NVME       | 4    | None        | Yes           | Home Assistant, Zwave2mqtt, OpenThread Border Router                                            | IN PROGRESS |
| Dokploy                 | Trinity | VM   | 16GB | 256GB              | NFS - NVME       | 8    | None        | Yes           | Dokploy platform and projects: sandbox, apps(N8N, Owntracks, Windmill, Vaultwarden, etc..)      | LIVE        |
| Media Stack             | Trinity | VM   | 8GB  | 64GB NVME, 8TB HDD | NFS - NVME, HDD  | 8    | Passthrough | Yes           | Caliber-Web, qBittorrent, SABnzbd                                                               | TODO        |
| Network File Server     | Smith   | LXC  | 1GB  | 8TB NVME, 28TB HDD | Node - NVME, HDD | 2    | None        | Yes           | NFS Server, SMB Server                                                                          | LIVE        |
| Backup Server           | Smith   | LXC  | 2GB  | 8TB NVME, 28TB HDD | Node - NVME, HDD | 4    | None        | Yes           | Rclone, Proxmox Backup Server                                                                   | LIVE        |
| UPS Management Stack    | Niobe   | VM   | 2GB  | 32GB               | NFS - NVME       | 1    | None        | Yes           | Network UPS Tools, Nutify                                                                       | LIVE        |
| Messaging Stack         | Niobe   | VM   | 2GB  | 64GB               | NFS - NVME       | 2    | None        | Yes           | Postfix, Element, Synapse, Matrix Bridges(WhatsApp, Discord, Signal, Telegram, Google Messages) | IN PROGRESS |
| Cockpit                 | Niobe   | VM   | 2GB  | 32GB               | NFS - NVME       | 2    | None        | Yes           | Cockpit                                                                                         | IN PROGRESS |
