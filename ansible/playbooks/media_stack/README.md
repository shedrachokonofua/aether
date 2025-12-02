# Media Stack

This playbook is for configuring the media stack virtual machine. The media stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- qBittorrent: BitTorrent client with web interface
- Gluetun: VPN client that routes all qBittorrent traffic through a VPN tunnel
- Prometheus qBittorrent Exporter: Lightweight Go-based exporter (~20x less RAM) that exports qBittorrent metrics including categories, tags, and trackers to Prometheus
- Prowlarr: Indexer manager/proxy
- SABnzbd: Usenet download client
- Filestash: Web-based file browser with video transcoding support
- Jellyfin: Media server for streaming movies, TV shows, music

## Planned Additions

- Calibre-Web: E-book library management
- Sonarr: TV series management

## Usage

```bash
task configure:home:media-stack
```

## Sub-Playbooks

### Mount NFS Share

Mounts the media NFS share from the network file server.

```bash
task ansible:playbook -- ./ansible/playbooks/media_stack/mount_nfs.yml
```

### Deploy qBittorrent

Deploys qBittorrent with Gluetun VPN client. All qBittorrent traffic is routed through ProtonVPN with port forwarding enabled.

```bash
task ansible:playbook -- ./ansible/playbooks/media_stack/qbittorrent.yml
```

### Deploy Prowlarr

Deploys Prowlarr indexer manager. Access the web UI at `<ip>:9696`.

```bash
task ansible:playbook -- ./ansible/playbooks/media_stack/prowlarr.yml
```

### Deploy SABnzbd

Deploys SABnzbd Usenet download client.

```bash
task ansible:playbook -- ./ansible/playbooks/media_stack/sabnzbd.yml
```

### Deploy Filestash

Deploys Filestash web-based file browser with video transcoding. Access at https://files.home.shdr.ch

```bash
task ansible:playbook -- ./ansible/playbooks/media_stack/filestash.yml
```

### Deploy Jellyfin

Deploys Jellyfin media server. Access at https://jellyfin.home.shdr.ch

Media libraries mounted at:

- `/media/nvme` → NVMe media (downloads, fast access)
- `/media/hdd` → HDD data (cold storage)

```bash
task ansible:playbook -- ./ansible/playbooks/media_stack/jellyfin.yml
```
