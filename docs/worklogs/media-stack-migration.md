# Media Stack → Talos k8s Migration

Migrate **qbittorrent, prowlarr, sabnzbd, aiostreams, stremthru** off the
`media-stack` VM (10.0.3.5, vmid 1020, podman quadlets) to Talos k8s, keeping
all on-disk state. Same playbook pattern as
`ansible/playbooks/media_stack/decommission_jellyfin_nzbdav_tuliprox.yml` and
the Dokploy migration in [dokploy-migration-2026-04.md](./dokploy-migration-2026-04.md).

## Source paths on media-stack VM

All quadlets run as user `aether`. Configs live in the user homedir; only
qbittorrent/sabnzbd touch a separate downloads volume.

| App | Config | Extra data |
|---|---|---|
| qbittorrent | `/home/aether/qbittorrent/config` | downloads dir gone (`/nvme/data` deleted) |
| prowlarr | `/home/aether/prowlarr/config` | — |
| sabnzbd | `/home/aether/sabnzbd/config` | downloads dir gone (`/nvme/data` deleted) |
| aiostreams | `/home/aether/aiostreams/data` | — |
| stremthru | `/home/aether/stremthru/data` | — |

> `/nvme/data` no longer exists on the VM. There is no in-flight download
> state to migrate — only configs. The k8s side needs a fresh `downloads`
> location (see below).

## Approach (mirrors jellyfin/nzbdav/tuliprox decommission)

1. **Build IaC first** — `tofu/home/kubernetes/{qbittorrent,prowlarr,sabnzbd,aiostreams,stremthru}.tf`,
   modeled on `jellyfin.tf`. Namespace `media`. Ceph RBD PVCs for each `/config`.
   Caddy routes flip from `vm.media_stack.ip` to k8s VIP / Gateway API.

   **Downloads volume (new — `/nvme/data` is gone)**: reuse the existing
   smith NFS export `/mnt/hdd/data` (jellyfin already mounts it via
   `kubernetes_persistent_volume_v1.media_hdd` in `jellyfin.tf`).
   `/mnt/hdd/data/downloads` likely already exists on smith — verify with
   `ls /mnt/hdd/data/` from any node that has the share mounted; create only
   if missing. Mount the existing `media_hdd` PVC into qbit and sabnzbd at
   `/downloads` with `sub_path = "downloads"`, so they share the same
   handoff dir and the *arrs (when migrated) reuse the same PVC + path with
   no rewriting.
2. **qBittorrent VPN sidecar (same Pod, no proxy alternative)** — gluetun
   runs as a sidecar container in the qbittorrent Pod. qbit shares gluetun's
   network namespace (default in k8s — all containers in a Pod share netns),
   so all qbit egress goes through the tunnel. Requirements:
   - Namespace `media` labeled `pod-security.kubernetes.io/enforce: privileged`
     (gluetun needs elevated caps).
   - gluetun container: `securityContext.capabilities.add: [NET_ADMIN, NET_RAW]`,
     `/dev/net/tun` mounted as a `hostPath` device. Talos workers have the `tun`
     module loaded by default — verify with a throwaway pod before writing the
     full module.
   - **Health/lifecycle coupling**: a gluetun crash cycles the whole Pod,
     pausing all torrents. Tune gluetun's `livenessProbe` carefully (e.g.
     check tunnel up via `HTTPCONTROL_SERVER_PORT`); avoid aggressive failure
     thresholds that flap on transient VPN provider hiccups.
   - **Startup ordering**: qbit can't bind until gluetun's tunnel is up.
     Either give qbit an `initContainer` that waits on gluetun's control API,
     or set qbit's `startupProbe` long enough to absorb gluetun's connect
     time (~30s).
   - **DNS leak check**: qbit must resolve through gluetun, not k8s
     CoreDNS. Set the Pod's `dnsPolicy: None` and `dnsConfig.nameservers` to
     gluetun's local DNS (gluetun runs its own resolver on `127.0.0.1:53`),
     or use gluetun's `DOT=on` and rely on it as the in-Pod resolver.
     Verify with `curl ifconfig.me` from inside the qbit container — must
     return the VPN exit IP, not your home WAN.
3. **Decommission playbook** — copy
   `decommission_jellyfin_nzbdav_tuliprox.yml` to
   `decommission_qbittorrent_etc.yml`. Steps:
   - Stop user-scope quadlets: `qbittorrent-pod`, `prowlarr`, `sabnzbd`,
     `aiostreams`, `stremthru` (qbit is a pod, the others are containers).
   - `tar czf` each config/data dir → fetch to `/tmp/media-stack-export/`.
   - Disable + remove `/home/aether/{app}` dirs only after k8s side restored.
   - No downloads dir to handle — `/nvme/data` is already gone, configs only.
     Expect qbit + sabnzbd to come up empty on the new `/downloads` PVC; that
     is the new ground truth. Old torrent entries in qbit will sit in "missing
     files" state until removed or re-fetched (acceptable since there's no
     prior data to reconcile).
4. **Restore into PVCs** — same recipe as the precedent:
   ```bash
   kubectl -n media cp /tmp/media-stack-export/qbittorrent-config.tar.gz qbittorrent-<POD>:/tmp/
   kubectl -n media exec qbittorrent-<POD> -- tar xzf /tmp/qbittorrent-config.tar.gz -C /config --strip-components=1
   kubectl -n media rollout restart deploy/qbittorrent
   ```
   Repeat for prowlarr (`/config`), sabnzbd (`/config` — also `sabnzbd.ini`
   is currently rendered from `sabnzbd.ini.j2`, so either render once into
   the PVC or keep templating in tofu), aiostreams (`/app/data`), stremthru
   (`/app/data`).
5. **Verify, then delete** — Caddyfile.j2 entries for the 5 apps swap to k8s
   VIP. Once green, drop the podman quadlets from
   `ansible/playbooks/media_stack/site.yml` and remove the corresponding
   `*.yml` playbooks. Don't decommission the VM yet (still hosts the *arrs +
   filestash + downloads volume).

## Gotchas to watch

- **qbit auth** — the existing `secrets.qbittorrent.{username,password}` in
  sops are used by the prometheus exporter. Reuse them in the k8s
  `qbittorrent-exporter` sidecar; don't rotate during migration.
- **Gluetun WireGuard key** — `secrets.qbittorrent.vpn_wireguard_private_key`
  goes into a k8s Secret, mounted as env on the gluetun container.
- **aiostreams `BUILTIN_STREMTHRU_URL`** — currently `http://10.0.3.5:<port>`.
  After migration: `http://stremthru.media.svc.cluster.local:<port>`.
- **Downloads path inside containers** — `/downloads` in both qbit and
  sabnzbd, backed by the new `nfs-hdd` PVC pointing at
  `/mnt/hdd/data/downloads` on smith. Pick this path now and keep it stable
  so future *arr migrations reuse the same PVC at the same path without any
  path rewriting in their configs.
- **Prometheus scrape** — `qbittorrent-exporter` currently scraped at
  `10.0.3.5:8090`. Update the monitoring stack scrape config to the new k8s
  ServiceMonitor / target.

## Backup belt-and-suspenders (optional)

For the same reason the Dokploy migration used RBD snapshots: the media-stack
VM disk is on Ceph RBD. Before running the decommission playbook:

```bash
# on trinity, root
SNAP=pre-media-migrate-$(date +%s)
rbd snap create vm-disks/vm-1020-disk-0@${SNAP}
rbd snap protect vm-disks/vm-1020-disk-0@${SNAP}
```

Keep the snapshot until the k8s side is verified, then `snap unprotect` +
`snap rm`. Same recipe as
[dokploy-migration-2026-04.md §Reference stash](./dokploy-migration-2026-04.md#reference-stash-in-repo-gitignored)
if you need to read individual files without booting anything.

## Order of operations

1. Build + commit the 5 tofu files (don't apply yet).
2. RBD snapshot of vm-1020.
3. `tofu apply` → 5 Deployments come up empty.
4. Run decommission playbook → tarballs land in `/tmp/media-stack-export/`.
5. `kubectl cp` + `tar xzf` each tarball into its PVC, restart Deployments.
6. Flip Caddyfile routes, run `task ansible:run -- playbooks/home_gateway_stack/site.yml`.
7. Smoke test: qbit WebUI auth + active torrents, prowlarr indexers, sabnzbd
   queue, aiostreams + stremthru endpoints reachable.
8. Drop quadlet playbooks from `media_stack/site.yml`.
9. Drop the RBD snapshot.
