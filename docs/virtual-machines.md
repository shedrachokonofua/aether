# Virtual Machines

All VMs and LXCs run on Proxmox VE across the five-host cluster. Storage is either local to the node or on Ceph distributed storage.

## Resource Allocation

| Name                    | Host    | Type | RAM   | Storage                      | Storage Location | vCPU | GPU         | HA            | Notes                                                                                           | Status      |
| ----------------------- | ------- | ---- | ----- | ---------------------------- | ---------------- | ---- | ----------- | ------------- | ----------------------------------------------------------------------------------------------- | ----------- |
| Router                  | Oracle  | VM   | 4GB   | 128GB                        | Node             | 8    | None        | PLANNED - ZFS | VyOs                                                                                            | LIVE        |
| Gateway Stack           | Oracle  | VM   | 4GB   | 128GB                        | Node             | 8    | None        | PLANNED - ZFS | UniFi Network Server, Caddy, AdGuard, Tailscale subnet router, HAProxy, WireProxy               | LIVE        |
| Development Workstation | Trinity | VM   | 16GB  | 256GB                        | Ceph             | 8    | None        | LIVE - Ceph   | Coder Server                                                                                    | LIVE        |
| Gaming Server           | Smith   | VM   | 16GB  | 256GB                        | Node - NVME      | 12   | Passthrough | N/A           | Bazzite VM: Steam, PS, PS2, PS3 simulation                                                      | LIVE        |
| GPU Workstation         | Neo     | VM   | 48GB  | 1TB                          | Node             | 32   | Passthrough | N/A           | Ollama + Models, Docling, ComfyUI, JupyterLab, SwarmUI, ClearML                                 | LIVE        |
| AI Tool Stack           | Neo     | VM   | 8GB   | 128GB                        | Ceph             | 4    | None        | LIVE - Ceph   | LiteLLM, SearXNG, Firecrawl, OpenWebUI, LibreChat, Bytebot                                      | LIVE        |
| Monitoring Stack        | Niobe   | VM   | 4GB   | 128GB                        | Node             | 4    | None        | PLANNED - ZFS | Prometheus, Grafana, Loki, Tempo, Otel Collector                                                | LIVE        |
| Gitlab                  | Trinity | VM   | 8GB   | 128GB                        | Ceph             | 8    | None        | LIVE - Ceph   | VCS, CI/CD, Package Registry                                                                    | LIVE        |
| Lute Stack              | Smith   | VM   | 40GB  | 256GB                        | Ceph             | 8    | None        | LIVE - Ceph   | Lute, Redis, Minio, Neo4j                                                                       | LIVE        |
| Dokku                   | Neo     | VM   | 8GB   | 256GB                        | Ceph             | 8    | None        | LIVE - Ceph   | Multi-tenant PaaS with Terraform support, Infisical                                             | LIVE        |
| IoT Management Stack    | Niobe   | VM   | 2GB   | 32GB                         | Ceph             | 4    | USB         | N/A           | Home Assistant, Zwave2mqtt, OpenThread Border Router                                            | IN PROGRESS |
| Dokploy                 | Trinity | VM   | 16GB  | 256GB                        | Ceph             | 8    | None        | LIVE - Ceph   | GUI based PaaS, sandbox + 3rd party apps(N8N, Owntracks, Windmill, Vaultwarden, etc..)          | LIVE        |
| Media Stack             | Trinity | VM   | 4GB   | 128GB                        | Ceph             | 4    | None        | LIVE - Ceph   | qBittorrent + VPN, Jellyfin, Calibre-Web, SABnzbd, immich                                       | LIVE        |
| Network File Server     | Smith   | LXC  | 1GB   | 10GB + NVME, HDD mountpoints | Node - NVME, HDD | 2    | None        | N/A           | NFS Server, SMB Server                                                                          | LIVE        |
| Backup Server           | Smith   | LXC  | 2GB   | 20GB + NVME, HDD mountpoints | Node - NVME, HDD | 4    | None        | N/A           | Rclone, Proxmox Backup Server                                                                   | LIVE        |
| Keycloak                | Oracle  | LXC  | 2GB   | 32GB                         | Node             | 2    | None        | PLANNED - ZFS | Identity Provider: OAuth2/OIDC, user management, service accounts                               | LIVE        |
| UPS Management Stack    | Niobe   | VM   | 2GB   | 32GB                         | Ceph             | 1    | None        | LIVE - Ceph   | Network UPS Tools, Peanut                                                                       | LIVE        |
| Messaging Stack         | Niobe   | VM   | 2GB   | 64GB                         | Ceph             | 2    | None        | LIVE - Ceph   | Postfix, Element, Synapse, Matrix Bridges(WhatsApp, Discord, Signal, Telegram, Google Messages) | LIVE        |
| Cockpit                 | Niobe   | VM   | 1GB   | 32GB                         | Ceph             | 1    | None        | LIVE - Ceph   | Cockpit                                                                                         | LIVE        |
| Wasm Cloud              | Trinity | LXC  | 2GB   | 32GB                         | Ceph             | 2    | None        | PLANNED - ZFS | wasmCloud Host, NATS                                                                            | PLANNED     |
| Smallweb                | Trinity | LXC  | 1GB   | 16GB                         | Ceph             | 2    | None        | LIVE - Ceph   | File-based personal cloud for lightweight apps                                                  | LIVE        |
| step-ca                 | Oracle  | LXC  | 1GB   | 16GB                         | Node             | 2    | None        | PLANNED - ZFS | Private CA: SSH certs, X.509, OIDC/JWK provisioners                                             | LIVE        |
| OpenBao                 | Oracle  | LXC  | 2GB   | 32GB                         | Node             | 2    | None        | PLANNED - ZFS | Secrets management: KV, dynamic credentials, Keycloak OIDC auth                                 | LIVE        |
| AdGuard                 | Oracle  | LXC  | 512MB | 16GB                         | Node             | 2    | None        | PLANNED - ZFS | AdGuard Home, AdGuard DNS, AdGuard Exporter                                                     | PLANNED     |

**HA Legend:** LIVE - Ceph = Proxmox HA enabled, PLANNED - ZFS = Needs ZFS reinstall (see [proxmox-ha.md](exploration/proxmox-ha.md)), N/A = Hardware passthrough or must survive storage failure

## Totals

| Metric | Allocated | Available |
| ------ | --------- | --------- |
| RAM    | 194GB     | 400GB     |
| vCPU   | 137       | 100       |
