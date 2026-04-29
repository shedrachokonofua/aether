# bastion

Break-glass admin host. Sits on **VLAN 2 (INFRA, 10.0.2.10)** as an unprivileged
NixOS LXC on `oracle`. Carries the lab toolchain (tofu, ansible, kubectl,
talosctl, bao, step, sops, glab, …) and exposes a browser SSH terminal at
`https://bastion.home.shdr.ch`.

The point of this box is to be reachable on a day everything else is on fire —
specifically, when the Talos cluster is broken. So it lives off k8s,
self-contained on Proxmox.

## Layout

| Layer | Where | Notes |
|---|---|---|
| LXC | `oracle`, id `1010`, VLAN tag `2` | NixOS image `nixos-base-lxc.tar.xz`, podman with nesting on |
| NixOS module | `nix/hosts/oracle/bastion.nix` | flake target `.#bastion` |
| Provisioning | `ansible/playbooks/bastion/site.yml` | clones the adguard pattern, plus step-ca cert bootstrap (the LXC analogue of cloud-init `write_files`) |
| Public TLS | home gateway Caddy → `10.0.2.10:4180` plain HTTP | `Caddyfile.j2` has the `bastion.home.shdr.ch` block; bastion has **no** local Caddy |
| Auth gate | `oauth2-proxy` on bastion, OIDC against Keycloak (client `bastion`) | `allowed-role = admin`; cookie name `_bastion_oauth2_proxy` to avoid collision with the gateway's `.shdr.ch`-scoped cookie |
| Backend | `termix` in podman, listening on `127.0.0.1:8080` inside the LXC | image `ghcr.io/lukegus/termix:latest`; container DNS pinned to AdGuard so version-check egress works |
| Secrets | `kv/aether/bastion` in OpenBao | written by `tofu/home/bastion.tf` (mints cookie via `random_password`, reads Keycloak client secret directly), rendered to `/run/secrets/oauth2-proxy.env` by `aether.openbao-agent` |

## Two access paths

1. **SSH cert (always):** `step ssh login` → SSH cert good for 16h → `ssh
   admin@bastion.home.shdr.ch`. This is the real escape hatch and works even
   when Keycloak / oauth2-proxy / Caddy are down.
2. **Browser terminal:** `https://bastion.home.shdr.ch` → Keycloak login (must
   hold realm role `admin`) → termix UI. Convenient, but depends on more
   moving pieces; never let it become the only way in.

## Deploy

```bash
task deploy:bastion          # provision + nixos-rebuild
# or in pieces:
task provision:bastion       # destroy + recreate the LXC, mint cert, push to /etc/ssl/
task configure:bastion       # nixos-rebuild via _nixos-deploy (rsync + remote build)
```

`task tofu:apply` (full or `-target=…bastion…`) creates the Keycloak client
and writes the Bao KV secret. Run that before the first deploy so vault-agent
has something to render.

## Things that bit during initial setup

- **OpenBao server cert was already expired** when bastion's vault-agent first
  tried to authenticate. Fixed via re-issuing through `task configure:openbao`,
  but only after a follow-on bug took bao down: the playbook regenerated
  `start-with-aws.sh` from `secrets/aws/openbao-kms.yml` (which didn't exist
  on the controller) and templated empty AWS ARNs. Recovery: `task
  provision:openbao-kms` regenerates the file from the live CloudFormation
  stack outputs (the dev shell now has `boto3` so this works without manual
  awscli fallback). Playbook is now idempotent on the leaf/chain split too —
  `cb005e4`.
- **Cookie collision** between the gateway's `.shdr.ch`-scoped `_oauth2_proxy`
  cookie and the bastion-local one. Renamed bastion's to `_bastion_oauth2_proxy`.
- **Container couldn't egress.** LXC booted with `net.ipv4.ip_forward=0` and
  podman's MASQUERADE rule had nothing to forward. Set explicitly via
  `boot.kernel.sysctl`. Stale netavark DNAT rules from previous container
  restarts also competed for `127.0.0.1:8080` — flush via
  `iptables -t nat -F NETAVARK-DN-…` then restart the container.
- **Container DNS** went through six public resolvers podman injects when
  the host uses systemd-resolved on `127.0.0.53`. Pinned to AdGuard
  (`facts.vm.adguard.ip`) so resolution is one hop, deterministic.

## Cert expiry monitoring

The Apr 2026 outage is the reason `blackbox-exporter` is now in the monitoring
pod and the `tls-cert-expiring-soon` Grafana alert exists. It probes
`10.0.2.9:8200`, `192.168.2.235:443`, and the gateway, and fires 14 days
before any of them roll past `NotAfter`. To add a new endpoint, edit the
`blackbox-tls` scrape targets in
`ansible/playbooks/monitoring_stack/prometheus.yml` and `task
configure:monitoring`.
