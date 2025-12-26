# TODOs

## P0

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
  - [ ] Keycloak OIDC provider in AWS IAM (human + app access)
  - [ ] GitLab identity provider in Keycloak (token exchange for CI)
  - [ ] step-ca trust anchor in IAM Roles Anywhere (machine workloads)
  - [ ] Migrate Backup Server from static credentials to IAM Roles Anywhere
- [ ] Prepare repo for open source
  - [ ] Add pre-commit hooks for secret detection
    - [ ] Create `.pre-commit-config.yaml` with gitleaks and custom SOPS checks
    - [ ] Add `.gitleaks.toml` for custom rules
  - [ ] Update SOPS workflow to never decrypt in place
    - [ ] Add `sops:edit` task (decrypts to /tmp, re-encrypts on save)
    - [ ] Add `sops:view` task (stdout only)
    - [ ] Add `sops:get` task (single value extraction)
    - [ ] Deprecate `sops:decrypt` / `sops:encrypt` in-place tasks
  - [ ] Add `.sops.yaml` config file to document encryption expectations
  - [ ] Update README with new SOPS workflow
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

- [ ] Create architecture diagrams
  - [ ] Network topology (physical, VLANs, firewall zones, traffic flows)
  - [ ] Compute layout (hosts → VMs/LXCs, resources, storage backends)
  - [ ] Storage architecture (ZFS pools, NFS/SMB exports, performance vs capacity tiers)
  - [ ] Backup flow (ZFS snapshots → PBS → S3 Glacier pipeline)
  - [ ] External access path (Cloudflare → AWS → Tailscale → home)
- [ ] Move dokku to Trinity
- [ ] Rewrite dev workstation to NixOS
- [ ] Move dev workstation to Neo
- [ ] Refactor public gateway as "Soren"
  - [ ] Rename to Soren in docs, Ansible, Tailscale
  - [ ] Upgrade Lightsail instance to micro ($5/mo)
  - [ ] Add Uptime Kuma for external monitoring
