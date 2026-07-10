# TODOs

## P0

- [ ] Certificate expiry alerting (step-ca file certs)
  - [ ] Add x509-certificate-exporter to vm_monitoring_agent role
  - [ ] Add cert expiry rules to Grafana alerting (<30% lifetime remaining)
  - [ ] Add cert renewal daemon health rules (systemd unit down)
- [ ] Deploy otel-journal-gatewayd-forwarder for pull-based host log collection ([exploration](exploration/journal-forwarder.md))
  - [ ] Publish versioned forwarder release + SHA-256 from CI (no `latest`)
  - [ ] Create `pki-journal-client` OpenBao mount (Tofu) + sign intermediate with step-ca root
  - [ ] Add `journal_gateway` role (Proxmox hosts: mTLS; public gateway: tailnet-bound)
  - [ ] Deploy vault-agent + forwarder to monitoring stack
  - [ ] Join monitoring stack to tailnet (`tag:monitoring`) + ACL to public gateway and uptime monitor :19531
  - [ ] Add forwarder alerts (poll stale/errors/absent) + document in monitoring.md

## P1

- [ ] Monitoring pre-migration hardening — survivable subset ([exploration](exploration/monitoring-stack-nix.md))
  - [ ] Pin all 13 container images (10 floating tags) — Track B prerequisite
  - [ ] Re-point Caddy route consumers (Goldilocks/Holmes/Orion) through Janus; drop raw routes
  - [ ] OTLP ingest bearer-token authn + direct receiver TLS (drop Caddy from ingest path; AdGuard rewrite, vcluster netpol, producers-first incl. vcluster + agent self-telemetry)
  - [ ] VyOS OTel producer -> https://otel.home.shdr.ch
  - [ ] Decommission Fleet (osquery agents off, fleet pod removed, route/secret/docs sweep; FIM/HIDS stays on Wazuh, CVEs on Trivy)
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
- [ ] Codify existing Grafana dashboards in Ansible (currently manual: Access Point, Disk Health, DNS, HAProxy, Hosts, IoT, ntfy, Postfix, PBS, Proxmox Cluster, qBittorrent, Reverse Proxy, Synapse, UPS)
- [ ] Enable SSH certificate auth for GitLab git push
  - [ ] Configure gitlab_sshd to trust step-ca user CA
    - [ ] Copy ssh_user_ca_key.pub to GitLab config
    - [ ] Add gitlab_sshd trusted_cert_file in gitlab.rb.j2
  - [ ] Update gitlab.yml playbook to deploy CA pubkey
  - [ ] Test step ssh login → git push workflow

## P2

- [ ] Remove east-west NAT masquerade — real source identity on mgmt net ([exploration](exploration/east-west-nat-removal.md))
  - [ ] Phase 0: live verification (pve-firewall, existing routes, conntrack snapshot)
  - [ ] Phase 1: consolidate return routes into one templated mechanism; add backup-stack, bazzite-builder, nfs
  - [ ] Phase 2: VyOS MGMT-ROUTED-HOSTS address group + NAT exclude rule 95
  - [ ] Phase 3: verify real sources + fallback masquerade for unmanaged devices
  - [ ] Phase 4: networking.md rewrite; retire journal-forwarder VyOS pre-NAT workaround
- [ ] Remove idle Knative Serving and operator resources (no declared or live KServices as of 2026-07-10)
- [ ] Adopt two-tier PKI: step-ca root tier, OpenBao issuing tier ([exploration](exploration/two-tier-pki.md))
  - [ ] Phase 0: `pki-journal-client` mount (with forwarder deployment)
  - [ ] Phase 1: freeze new step-ca provisioners; update trust-model.md with issuing-tier policy
  - [ ] Phase 2: `pki-machine` mount; migrate machine certs opportunistically with NixOS migrations
  - [ ] Add mount intermediate CAs to cert-expiry alerting; enable PKI tidy
- [ ] Deploy patch management stack ([exploration](exploration/patch-management.md))
  - [ ] Deploy WUD for container update visibility
  - [ ] Deploy Trivy for CVE scanning
  - [ ] Deploy Ansible Semaphore for controlled deployment
  - [ ] Create Grafana dashboard for unified view
- [ ] Complete Tailscale integration ([exploration](exploration/full-tailscale-integration.md))
  - [ ] Phase 2: Gateway credential security (WIF)
  - [ ] Phase 3: VyOS route for home → Tailnet
  - [ ] Phase 4: MagicDNS via AdGuard
- [x] Deploy IDS stack as NixOS VM ([exploration](exploration/network-security.md))
  - [x] Create NixOS config (`nix/hosts/oracle/ids-stack.nix`)
  - [x] Provision VM on Oracle via Tofu
  - [x] Deploy via nixos-rebuild --target-host
  - [x] Configure VyOS port mirror to span port
  - [x] Deploy Zeek for network traffic analysis (quadlet-nix)
  - [x] Deploy Suricata on VyOS router directly
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

## P3

- [ ] Continue NixOS migration ([docs](../nixos.md), [exploration](exploration/nixos.md))
  - [x] Dev shell (`nix develop`) - replaced Docker toolbox
  - [x] AdGuard LXC - DNS, OTEL, Prometheus exporter
  - [x] IDS Stack VM - Zeek via quadlet-nix
  - [x] Blockchain Stack VM - bitcoind, monerod, Fulcrum (quadlet)
  - [ ] Migrate Gateway Stack (Caddy, Tailscale, HAProxy)
  - [ ] Migrate Oracle identity stack (Keycloak, step-ca, OpenBao) via nixos-generators LXC
  - [ ] Migrate Monitoring Stack ([exploration](exploration/monitoring-stack-nix.md) Track B; prereqs: journal forwarder, codified dashboards, pinned images; absorbs deferred hardening: dir ownership, port non-publication, Fleet TLS, exporter TLS verify)
  - [ ] Migrate IoT Stack
- [ ] Refactor public gateway as "Soren"
  - [ ] Rename to Soren in docs, Ansible, Tailscale
  - [ ] Upgrade Lightsail instance to micro ($5/mo)
  - [ ] Add Uptime Kuma for external monitoring
- [ ] Move Tofu state to Ceph RGW
