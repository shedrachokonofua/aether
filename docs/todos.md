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
- [ ] Split AdGuard from Gateway Stack (NixOS LXC)
  - [x] Set up nix/ directory with flake.nix
  - [x] Build AdGuard NixOS LXC config
  - [x] Provision standalone LXC on Oracle (Gigahub network for VyOS-independent DNS)
  - [x] Deploy AdGuard
  - [x] Update VyOS DNS forwarding to point at new AdGuard IP
  - [ ] Update Caddy upstream IP for admin UI
  - [ ] Remove from gateway stack playbook

## P1

- [ ] Enable Proxmox HA for critical VMs ([exploration](exploration/proxmox-ha.md))
  - [ ] Convert Trinity to local-zfs
  - [ ] Convert Oracle to local-zfs
  - [ ] Convert Niobe to local-zfs
  - [ ] Configure HA resources in Tofu
- [ ] Direct Cloudflare ACME cert for Keycloak (after AdGuard split)
  - [ ] Create Ansible role for certbot + cloudflare plugin
  - [ ] Deploy to Keycloak LXC (auth.shdr.ch)
  - [ ] Configure cert renewal hook (systemd reload)
  - [ ] Remove Caddy proxy route for auth.shdr.ch
  - [ ] Update AdGuard DNS to point directly at Keycloak
- [ ] Enroll Cockpit with step-ca (SSH user cert, auto-renewal)
- [ ] Codify existing Grafana dashboards in Ansible (currently manual: Access Point, Disk Health, DNS, HAProxy, Hosts, IoT, ntfy, Postfix, PBS, Proxmox Cluster, qBittorrent, Reverse Proxy, Synapse, UPS)
- [ ] Integrate SSO (OIDC-native apps)
  - [ ] LiteLLM
  - [ ] Dokploy
  - [ ] Infisical
  - [ ] Element
  - [ ] Affine
  - [ ] N8N
- [ ] Enable SSH certificate auth for GitLab git push
  - [ ] Configure gitlab_sshd to trust step-ca user CA
    - [ ] Copy ssh_user_ca_key.pub to GitLab config
    - [ ] Add gitlab_sshd trusted_cert_file in gitlab.rb.j2
  - [ ] Update gitlab.yml playbook to deploy CA pubkey
  - [ ] Test step ssh login → git push workflow
- [ ] Replace Jellyseer, Sonarr, Radarr with MediaManager

## P2

- [ ] Deploy Kubernetes cluster ([exploration](exploration/kubernetes.md))
  - [ ] Provision 3 Talos VMs via Tofu (Trinity, Niobe, Neo)
  - [ ] Bootstrap Talos cluster
  - [ ] Install Cilium, Gateway API, Knative, OPA Gatekeeper
  - [ ] Install Kubero (replaces Dokku + Dokploy)
  - [ ] Install Secrets Store CSI + cert-manager
  - [ ] Configure OTEL Collector → external Monitoring Stack
  - [ ] Register GitLab Agent
  - [ ] Migrate AI Tool Stack, Messaging Stack, Lute Stack
  - [ ] Migrate Media Stack (rffmpeg → GPU Workstation for transcoding)
  - [ ] Migrate Dokku/Dokploy apps to Kubero
  - [ ] Configure multi-tenancy (namespaces, quotas, Keycloak OIDC)
- [ ] Deploy patch management stack ([exploration](exploration/patch-management.md))
  - [ ] Deploy WUD for container update visibility
  - [ ] Deploy Trivy for CVE scanning
  - [ ] Deploy Ansible Semaphore for controlled deployment
  - [ ] Create Grafana dashboard for unified view
- [ ] Deploy Fleet/osquery for host visibility ([exploration](exploration/osquery.md))
  - [ ] Deploy Fleet server on Monitoring Stack
  - [ ] Add osquery agent to vm_monitoring_agent role
  - [ ] Configure scheduled queries and policies
- [ ] Complete Tailscale integration ([exploration](exploration/full-tailscale-integration.md))
  - [ ] Phase 2: Gateway credential security (WIF)
  - [ ] Phase 3: VyOS route for home → Tailnet
  - [ ] Phase 4: MagicDNS via AdGuard
- [ ] Deploy network security stack as NixOS VM ([exploration](exploration/network-security.md))
  - [ ] Create NixOS config for Network Security Stack
  - [ ] Provision VM on Oracle via Tofu
  - [ ] Deploy via nixos-rebuild --target-host
  - [ ] Configure VyOS port mirror to span port
  - [ ] Deploy Suricata with ET Open rules
  - [ ] Deploy Nuclei for vulnerability scanning
  - [ ] Add Wazuh agents to vm_monitoring_agent role
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
- [ ] Deploy rffmpeg server on GPU Workstation (Jellyfin remote transcoding)
- [ ] Add TTS/STT inference to GPU Workstation
- [ ] Integrate Matter/Thread border router into IoT stack
- [ ] Deploy wasmCloud LXC

## P3

- [ ] Continue NixOS migration ([docs](../nixos.md), [exploration](exploration/nixos.md))
  - [ ] Migrate Gateway Stack
  - [ ] Migrate Oracle identity stack (Keycloak, step-ca, OpenBao) via nixos-generators LXC
  - [ ] Migrate Monitoring Stack
  - [ ] Migrate Dev Workstation
  - [ ] Migrate IoT Stack
  - [ ] Deploy Desktop VM on Trinity ([exploration](exploration/desktop-vm.md))
    - [ ] Configure iGPU passthrough (freed from Media Stack)
    - [ ] NixOS with KDE/GNOME/Hyprland configs
    - [ ] Sunshine for streaming
    - [ ] Distrobox for multi-distro dev
- [ ] Move dev workstation to Neo
- [ ] Refactor public gateway as "Soren"
  - [ ] Rename to Soren in docs, Ansible, Tailscale
  - [ ] Upgrade Lightsail instance to micro ($5/mo)
  - [ ] Add Uptime Kuma for external monitoring
