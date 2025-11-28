# Media Stack

This playbook is for configuring the media stack virtual machine. The media stack is a fedora vm that hosts the following applications deployed as podman quadlets:

- qBittorrent: BitTorrent client with web interface
- Gluetun: VPN client that routes all qBittorrent traffic through a VPN tunnel
- Prometheus qBittorrent Exporter: Lightweight Go-based exporter (~20x less RAM) that exports qBittorrent metrics including categories, tags, and trackers to Prometheus

## Planned Additions

- Jellyfin: Media server for streaming movies, TV shows, music
- Calibre-Web: E-book library management
- SABnzbd: Usenet client

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

## VPN Configuration

Add ProtonVPN credentials to `secrets/secrets.yml`:

```yaml
qbittorrent_vpn_provider: "protonvpn"
qbittorrent_vpn_type: "openvpn"
qbittorrent_vpn_user: "your-openvpn-username+pmp" # Add +pmp suffix for port forwarding
qbittorrent_vpn_password: "your-openvpn-password"
qbittorrent_vpn_server_countries: "US" # Optional
qbittorrent_vpn_port_forwarding: "on"
```

Get your credentials from https://account.proton.me/u/0/vpn/OpenVpnIKEv2

After deployment, check Gluetun logs for the forwarded port and configure it in qBittorrent settings → Connection → Listening Port.
