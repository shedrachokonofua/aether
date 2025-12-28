# TODOs

## P0

- [ ] Certificate expiry alerting (step-ca file certs)
  - [ ] Add x509-certificate-exporter to vm_monitoring_agent role
  - [ ] Add cert expiry rules to Grafana alerting (<30% lifetime remaining)
  - [ ] Add cert renewal daemon health rules (systemd unit down)
- [ ] Make host_monitoring_agent role OS-generic (Debian + Amazon Linux)
- [ ] Deploy otel-journal-gatewayd-forwarder for pull-based host log collection
  - [ ] Add journal-gatewayd to host_monitoring_agent role
  - [ ] Deploy forwarder to monitoring stack
  - [ ] Configure sources for all Proxmox hosts + public gateway
- [ ] Setup iGPU passthrough on Trinity for Media Stack (Jellyfin hardware transcoding)
- [ ] Split AdGuard from Gateway Stack
  - [ ] Provision standalone LXC on Oracle (Gigahub network for VyOS-independent DNS)
  - [ ] Deploy AdGuard
  - [ ] Update Caddy upstream IP for admin UI
  - [ ] Update VyOS DHCP to point at new IP
  - [ ] Remove from gateway stack playbook

## P1

- [ ] Direct Cloudflare ACME cert for Keycloak (after AdGuard split)
  - [ ] Create Ansible role for certbot + cloudflare plugin
  - [ ] Deploy to Keycloak LXC (auth.shdr.ch)
  - [ ] Configure cert renewal hook (systemd reload)
  - [ ] Remove Caddy proxy route for auth.shdr.ch
  - [ ] Update AdGuard DNS to point directly at Keycloak
- [ ] Enroll Cockpit with step-ca (SSH user cert, auto-renewal)
- [ ] Deploy AdGuard HA
  - [ ] Provision secondary LXC on Niobe (Gigahub network for VyOS-independent DNS)
  - [ ] Configure AdGuard sync between primary/secondary
  - [ ] Update VyOS DHCP with both DNS servers
- [ ] Configure AWS federation
  - [ ] Migrate Backup Server from static credentials to IAM Roles Anywhere
- [ ] Codify existing Grafana dashboards in Ansible (currently manual: Access Point, Disk Health, DNS, HAProxy, Hosts, IoT, ntfy, Postfix, PBS, Proxmox Cluster, qBittorrent, Reverse Proxy, Synapse, UPS)
- [ ] Integrate SSO (OIDC-native apps)
  - [ ] LiteLLM
  - [ ] Dokploy
  - [ ] Infisical
  - [ ] Element
  - [ ] Affine
  - [ ] N8N
  - [ ] SeaweedFS
- [ ] Enable SSH certificate auth for GitLab git push
  - [ ] Configure gitlab_sshd to trust step-ca user CA
    - [ ] Copy ssh_user_ca_key.pub to GitLab config
    - [ ] Add gitlab_sshd trusted_cert_file in gitlab.rb.j2
  - [ ] Update gitlab.yml playbook to deploy CA pubkey
  - [ ] Test step ssh login → git push workflow
- [ ] Replace Jellyseer, Sonarr, Radarr with MediaManager

## P2

- [ ] Consolidate ProtonVPN infrastructure
  - [ ] Unify secrets under `secrets.protonvpn.*` (move qbittorrent VPN creds)
  - [ ] Switch qBittorrent from Gluetun to tun2socks → rotating-proxy
  - [ ] Configure SearXNG to use rotating-proxy SOCKS5
  - [ ] Configure Firecrawl to use rotating-proxy SOCKS5
  - [ ] Configure Prowlarr to use rotating-proxy SOCKS5
- [ ] Create disaster recovery runbook (ZFS rollback, PBS restore, S3 recovery procedures)
- [ ] Integrate SSO (reverse proxy / quirky auth)
  - [ ] Home Assistant
  - [ ] qBittorrent
  - [ ] SABnzbd
  - [ ] Prowlarr
  - [ ] Homarr
- [ ] Add TTS/STT inference to GPU Workstation
- [ ] Integrate Matter/Thread border router into IoT stack
- [ ] Deploy wasmCloud LXC

## P3

- [ ] Move dokku to Trinity
- [ ] Rewrite dev workstation to NixOS
- [ ] Move dev workstation to Neo
- [ ] Refactor public gateway as "Soren"
  - [ ] Rename to Soren in docs, Ansible, Tailscale
  - [ ] Upgrade Lightsail instance to micro ($5/mo)
  - [ ] Add Uptime Kuma for external monitoring
