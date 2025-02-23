# Home Lab Workload Map

## Available Resources

| Host    | RAM   | Storage                                        | CPU                  | GPU                   | Cores | Threads | vCPUs | Ethernet |
| ------- | ----- | ---------------------------------------------- | -------------------- | --------------------- | ----- | ------- | ----- | -------- |
| Oracle  | 16GB  | 512GB                                          | Intel Core i5-12600H | Intel Iris Xe         | 12    | 16      | 16    | 10G      |
| Smith   | 128GB | 8TB NVME(4tb x2) + 2TB SDD + 56TB HDD(14tb x4) | AMD Ryzen 7 3700X    | Nvidia RTX 1660 Super | 8     | 16      | 16    | 10G      |
| Niobe   | 64GB  | 1.5TB                                          | AMD Ryzen 9 6900HX   | AMD Radeon 680M       | 8     | 16      | 16    | 2.5G     |
| Neo     | 96GB  | 4TB                                            | AMD Rzyen 9 9950     | Nvidia RTX A6000      | 16    | 16      | 32    | 10G      |
| Trinity | 64GB  | 1TB                                            | Intel Core i9-13900H | Intel Iris Xe         | 14    | 20      | 20    | 10G      |

## Resource Allocation

| Name                  | Host    | Type | RAM  | Storage                         | Storage Location      | vCPU | GPU         | On By Default | Notes                                                                                                            |
| --------------------- | ------- | ---- | ---- | ------------------------------- | --------------------- | ---- | ----------- | ------------- | ---------------------------------------------------------------------------------------------------------------- |
| Router                | Oracle  | VM   | 4GB  | 192GB                           | Node                  | 8    | None        | Yes           | VyOs                                                                                                             |
| Gateway Stack         | Oracle  | VM   | 2GB  | 192GB                           | Node                  | 8    | None        | Yes           | UniFi Network Server, Caddy, Casdoor, AdGuard, Tailscale subnet router                                           |
| Desktop Environment   | Niobe   | VM   | 16GB | 512GB                           | Nas - NVME            | 8    | Passthrough | No            | Linux DE: Browser, IDEs, Writing, Admin                                                                          |
| Development Server    | Neo     | VM   | 32GB | 1TB                             | Node                  | 24   | None        | Yes           | VS Code Server                                                                                                   |
| Gaming Server         | Smith   | VM   | 16GB | 512GB                           | Node - SSD            | 8    | Passthrough | No            | Windows VM: Steam, PS2, PS3, Xbox 360 simulation                                                                 |
| AI Stack              | Neo     | VM   | 48GB | 1TB                             | Node                  | 24   | Passthrough | Yes           | Custom AI Gateway, Ollama, Llama 3.3 70b, Qwen 2.5 Coder 32b, Gemma 2 27b, mxbai-embed-large, Whisper, XTTS      |
| Observability Stack   | Niobe   | VM   | 4GB  | 256GB                           | Node                  | 4    | None        | Yes           | Otel Collector, Prometheus, Grafana, Tempo, Loki, Promtail, Pyroscope                                            |
| Gitlab                | Trinity | LXC  | 8GB  | 256GB                           | Nas - NVME            | 8    | None        | Yes           | VCS, CI/CD, Container Registry, Package Registry                                                                 |
| Lute Stack            | Smith   | VM   | 32GB | 256GB                           | Nas - NVME            | 8    | None        | Yes           | Lute, Redis, Minio, Neo4j                                                                                        |
| Home Automation Stack | Niobe   | VM   | 4GB  | 16GB                            | Nas - NVME            | 4    | None        | Yes           | Home Assistant, Zwave2mqtt                                                                                       |
| Coolify               | Trinity | VM   | 32GB | 256GB                           | Nas - NVME            | 16   | None        | Yes           | Coolify platform and projects: sandbox, tools(Matrix, OpenWebUI, N8N, Owntracks, Memos, Jupyter, Flowise, etc..) |
| Media Stack           | Trinity | VM   | 8GB  | 8TB                             | Nas - HDD             | 8    | Passthrough | Yes           | Jellyfin, Plex, arr stack                                                                                        |
| Nas                   | Smith   | VM   | 32GB | 8TB NVME + 28TB HDD + 256GB SSD | Node - NVME, SSD, HDD | 8    | None        | Yes           | TrueNAS Scale: ZFS                                                                                               |
| Proxmox Backup Server | Smith   | VM   | 32GB | 28TB HDD + 256GB SSD            | Node - SSD, HDD       | 8    | None        | Yes           | Proxmox Backup Server                                                                                            |
| Old PC                | Niobe   | VM   | 16GB | 1TB                             | Node                  | 8    | None        | No            | VM booting from old PC's nvme, for preservation                                                                  |
