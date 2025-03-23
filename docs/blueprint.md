# Blueprint

## Home

### Available Resources

| Host    | RAM   | Storage                              | CPU                  | GPU                       | Cores | Threads | vCPUs | Ethernet | Status |
| ------- | ----- | ------------------------------------ | -------------------- | ------------------------- | ----- | ------- | ----- | -------- | ------ |
| Oracle  | 16GB  | 1TB                                  | Intel Core i5-12600H | Intel Iris Xe             | 12    | 16      | 16    | 10G      | LIVE   |
| Smith   | 128GB | 8TB NVME(4TB x2) + 56TB HDD(14TB x4) | AMD Ryzen 7 3700X    | Nvidia RTX 1660 Super     | 8     | 16      | 16    | 10G      | LIVE   |
| Niobe   | 64GB  | 1.5TB                                | AMD Ryzen 9 6900HX   | AMD Radeon 680M           | 8     | 16      | 16    | 2.5G     | LIVE   |
| Neo     | 128GB | 2TB                                  | AMD Rzyen 9 9950X3D  | Nvidia RTX Pro 6000 Max-Q | 16    | 16      | 32    | 10G      | TODO   |
| Trinity | 64GB  | 1TB                                  | Intel Core i9-13900H | Intel Iris Xe             | 14    | 20      | 20    | 10G      | LIVE   |

### Resource Allocation

| Name                   | Host    | Type | RAM  | Storage            | Storage Location | vCPU | GPU         | On By Default | Notes                                                                                                            | Status      |
| ---------------------- | ------- | ---- | ---- | ------------------ | ---------------- | ---- | ----------- | ------------- | ---------------------------------------------------------------------------------------------------------------- | ----------- |
| Router                 | Oracle  | VM   | 4GB  | 128GB              | Node             | 8    | None        | Yes           | VyOs                                                                                                             | LIVE        |
| Gateway Stack          | Oracle  | VM   | 4GB  | 128GB              | Node             | 8    | None        | Yes           | UniFi Network Server, Caddy, Ory Stack, AdGuard, Tailscale subnet router                                         | LIVE        |
| Desktop Environment    | Niobe   | VM   | 16GB | 256GB              | NFS - NVME       | 8    | Passthrough | No            | Linux DE: Browser, IDEs, Writing, Admin                                                                          | TODO        |
| Development Server     | Neo     | VM   | 32GB | 512GB              | Node             | 24   | vGPU        | Yes           | VS Code Server                                                                                                   | TODO        |
| Gaming Server          | Smith   | VM   | 16GB | 512GB              | Node - NVME      | 8    | Passthrough | No            | Windows VM: Steam, PS2, PS3, Xbox 360 simulation                                                                 | TODO        |
| AI Stack               | Neo     | LXC  | 48GB | 512GB              | Node             | 24   | vGPU        | Yes           | Ollama, Llama 3.3 70b, Gemma 3 27b, QwQ 32b, mxbai-embed-large, snowflake-arctic-embed2, Whisper, XTTS           | TODO        |
| Monitoring Stack       | Niobe   | VM   | 4GB  | 128GB              | Node             | 4    | None        | Yes           | Otel Collector, Prometheus, Grafana, Tempo, Loki, Promtail, Pyroscope                                            | IN PROGRESS |
| Gitlab                 | Trinity | LXC  | 8GB  | 128GB              | NFS - NVME       | 8    | None        | Yes           | VCS, CI/CD, Container Registry, Package Registry                                                                 | TODO        |
| Lute Stack             | Smith   | VM   | 32GB | 256GB              | NFS - NVME       | 8    | None        | Yes           | Lute, Redis, Minio, Neo4j                                                                                        | TODO        |
| Home Automation Stack  | Niobe   | VM   | 2GB  | 32GB               | NFS - NVME       | 4    | None        | Yes           | Home Assistant, Zwave2mqtt                                                                                       | TODO        |
| Coolify                | Trinity | VM   | 16GB | 256GB              | NFS - NVME       | 16   | None        | Yes           | Coolify platform and projects: sandbox, tools(Matrix, OpenWebUI, N8N, Owntracks, Memos, Jupyter, Flowise, etc..) | TODO        |
| Media Stack            | Trinity | VM   | 8GB  | 64GB NVME, 8TB HDD | NFS - NVME, HDD  | 8    | Passthrough | Yes           | Jellyfin, Caliber-Web, qBittorrent, Sonarr, Radarr, Lidarr, Readarr, Prowlarr, Bazarr, SABnzbd                   | TODO        |
| Network File Server    | Smith   | LXC  | 4GB  | 8TB NVME, 28TB HDD | Node - NVME, HDD | 4    | None        | Yes           | NFS Server, SMB Server                                                                                           | IN PROGRESS |
| Backup Server          | Smith   | LXC  | 8GB  | 8TB NVME, 28TB HDD | Node - NVME, HDD | 4    | None        | Yes           | Rclone, Proxmox Backup Server                                                                                    | TODO        |
| Power Management Stack | Niobe   | VM   | 2GB  | 32GB               | NFS - NVME       | 2    | None        | Yes           | Network UPS Tools, PeaNUT                                                                                        | TODO        |
| Old PC                 | Niobe   | VM   | 16GB | 1TB                | Node             | 8    | None        | No            | VM booting from old PC's nvme, for preservation                                                                  | TODO        |

## AWS

- Home S3 backup bucket
- Bedrock: Claude, Llama

## GCP

- Assistant API for homeassistant
- Drive API for personal dataset backups
- Generative Language API: Gemini
- Document OCR Processor
