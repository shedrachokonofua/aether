# Dokploy Migration — April 2026

Comprehensive handoff covering the audit, backup operations, IaC built, and
all remaining work as of commit `554735a` on branch `migration/nextcloud-k8s`.

---

## Context

Started from a Prometheus/Caddy metrics query revealing ~39 active Dokploy
stacks, many unused. Goal: reduce Dokploy footprint, migrate critical apps to
Talos k8s (consistent with the ongoing AI/Immich k8s migrations), replace
Homarr with a Grafana home dashboard, and add a self-hosted Drive.

Key constraints decided during the session:
- **IaC is paramount** — no click-through config, everything in Tofu or Ansible
- **No CPU-heavy wasm workloads on the cluster**
- **Storage**: Ceph RBD for k8s PVCs, Ceph RGW for S3 objectstore, NFS (smith) for large media libraries
- **Auth**: Keycloak (`auth.shdr.ch/realms/aether`) SSO on everything possible
- **No credential changes without explicit permission**

---

## What Was Done This Session

### Disk inspection (read-only, non-destructive)

All disk reads were done via RBD snapshot → writable clone → btrfs mount on
`trinity` (192.168.2.202). Every snapshot and clone was fully cleaned up after
each operation. No writes were made to the live dokploy VM (10.0.3.6).

### Exports saved locally (your Mac, not in repo)

| Path | Contents | Size |
|---|---|---|
| `~/nextcloud-export/shedrachokonofua@gmail.com/` | Nextcloud user files | 153 MB |
| `~/nextcloud-export/browser-use-agent/` | Old experiment user (3 files) | 24 KB |
| `~/notes-export/silverbullet-2/` | Active SilverBullet markdown (10 .md files) | 272 KB |
| `~/notes-export/silverbullet/` | Older SilverBullet instance (5 .md files) | 124 KB |
| `~/dokploy-archive/freshrss.tgz` | FreshRSS sqlite + extensions | 2.7 MB |
| `~/dokploy-archive/homarr-config.tgz` | Homarr appdata (sqlite + redis dump) | 5.1 MB |
| `~/dokploy-archive/coder-workspace.tgz` | Coder workspace home dir | 967 MB |
| `~/Downloads/` | Vaultwarden export (you did this manually) | — |

**Security note**: if the Vaultwarden export in `~/Downloads/` is unencrypted
JSON, re-export with "password-protected JSON" and delete the unencrypted file.

### Reference stash (in repo, gitignored)

`.dokploy-ref/` contains 39 stack compose YAMLs + partially redacted `.env`
files, captured from `/etc/dokploy/compose/` on the live VM. Directory layout:

```
.dokploy-ref/
  README.md                         ← inventory + capture timestamp
  default-affine-ghfpkn/
    docker-compose.yml              ← full compose (no secrets)
    .env.redacted                   ← env with PASSWORD/KEY/TOKEN values replaced
    files/                          ← bind-mounted config files (e.g. config.json)
  default-hoarder-xlt9m2/
    docker-compose.yml
    .env.redacted
  ... (one dir per stack)
```

**What's redacted**: any env line whose key matches `PASSWORD|SECRET|KEY|TOKEN|
API|DSN|PASS|AUTH|CRED|SALT|HASH` has its value replaced with `***REDACTED***`.

**Getting the real values** — three options, in order of preference:

1. **Fix SSH first (fastest once done):** add your Mac pubkey to `aether@10.0.3.6`
   via the Proxmox console (`qm terminal 1005` on trinity), then:
   ```bash
   ssh aether@10.0.3.6 'sudo cat /etc/dokploy/compose/<stack>/code/.env'
   ```

2. **RBD snapshot (no SSH required):** the method used throughout this session.
   Run this on trinity as root — it mounts the live disk read-only without
   touching the VM:
   ```bash
   SNAP=read-$(date +%s)
   rbd snap create vm-disks/vm-1005-disk-0@${SNAP}
   rbd snap protect vm-disks/vm-1005-disk-0@${SNAP}
   CLONE=vm-1005-clone-$(date +%s)
   rbd clone vm-disks/vm-1005-disk-0@$SNAP vm-disks/$CLONE
   DEV=$(rbd map vm-disks/$CLONE)
   mkdir -p /tmp/dokploy-ro && mount -t btrfs ${DEV}p4 /tmp/dokploy-ro
   # Read what you need, e.g.:
   cat /tmp/dokploy-ro/root/etc/dokploy/compose/<stack>/code/.env
   # Then clean up:
   umount /tmp/dokploy-ro && rmdir /tmp/dokploy-ro
   rbd unmap $DEV
   rbd rm vm-disks/$CLONE
   rbd snap unprotect vm-disks/vm-1005-disk-0@$SNAP
   rbd snap rm vm-disks/vm-1005-disk-0@$SNAP
   ```

3. **Dokploy web UI:** `d.home.shdr.ch` → open the app → Environment tab shows
   the current env values in plaintext (authenticated Dokploy session required).

**On-disk layout on the VM** (for reference):
```
/etc/dokploy/compose/<stack-name>/
  code/
    docker-compose.yml    ← the compose file Dokploy manages
    .env                  ← env file Dokploy injects
  files/                  ← extra bind-mounts (configs, seeds, etc.)
  <app-name>/             ← bind-mounted data dirs (e.g. silverbullet-2, postgres_data)
```

Docker named volumes (for image-managed data like sqlite, postgres data dirs)
live at `/var/lib/docker/volumes/<project-name>_<volume-name>/_data` on the VM,
which sits on the btrfs `var` subvolume — accessible via the RBD snapshot method
above (option 2).

### IaC built and committed (`migration/nextcloud-k8s` branch, commit `554735a`)

- `tofu/home/kubernetes/nextcloud.tf` — Nextcloud 32 Drive on Talos k8s
- `tofu/home/kubernetes/nextcloud_config.php.tftpl` — config.php template
- `tofu/home/keycloak.tf` — `nextcloud_user` role + `nextcloud` OIDC client
- `tofu/home/kubernetes/main.tf` — 3 new sensitive variables
- `tofu/home/talos_cluster.tf` — module wiring for new vars
- `ansible/playbooks/configure_ceph_rgw_accounts.yml` — nextcloud RGW play (tagged `nextcloud`)
- `.gitignore` — excludes `.dokploy-ref/`

---

## Nextcloud Stack Architecture

```
cloud.apps.home.shdr.ch  (Caddy wildcard *.apps.home.shdr.ch → Cilium L2 VIP 10.0.3.19)
        │
        ▼
   Gateway API (HTTPRoute)
        │
        ▼
   nextcloud-server (Deployment, nextcloud:32-apache)
        │         │
        │    /var/www/html ──→ nextcloud-app PVC (5Gi, Ceph RBD)
        │    config.php    ──→ nextcloud-config Secret (mounted read-only)
        │
        ├──→ nextcloud-postgres (StatefulSet, postgres:16-alpine)
        │         └──→ nextcloud-postgres-data PVC (20Gi, Ceph RBD)
        │
        └──→ nextcloud-redis (Deployment, redis:7-alpine, no PVC)

   nextcloud-cron (Deployment, same image, runs /cron.sh every 5m)
   nextcloud-oidc-bootstrap (Job, runs once after install, registers Keycloak)

   User files → Ceph RGW S3 (bucket: nextcloud) via objectstore primary
```

### Mobile client setup
The Nextcloud iOS/Android app uses Login Flow v2. The Keycloak client redirect
URI `nc://login/server:https://cloud.apps.home.shdr.ch` handles the final app
callback. Set auto-upload to **non-photo folders only** — Immich owns photos.

---

## Pre-Apply Checklist for Nextcloud

Do these **in order** before `task tofu:apply`:

- [ ] **Add secrets to sops**: `sops edit secrets/secrets.yml`
  ```yaml
  ceph:
    nextcloud_s3_access_key: <generate with: openssl rand -hex 20>
    nextcloud_s3_secret_key: <generate with: openssl rand -hex 32>
  ```

- [ ] **Provision RGW user + bucket**:
  ```bash
  task ansible:run -- playbooks/configure_ceph_rgw_accounts.yml --tags nextcloud
  ```
  This creates the `nextcloud` RGW user (using the creds from secrets.yml) and
  the `nextcloud` bucket. Idempotent — safe to re-run.

- [ ] **Apply Tofu** (Keycloak OIDC client is created here):
  ```bash
  task tofu:apply
  ```

- [ ] **First login**: `tofu output -raw nextcloud_admin_password` — use once,
  then change the admin password inside Nextcloud UI. The Job
  `nextcloud-oidc-bootstrap` will automatically register Keycloak as the OIDC
  provider (watch its logs with `kubectl logs -n nextcloud job/nextcloud-oidc-bootstrap`).

- [ ] **Install Nextcloud mobile app** → log in with Keycloak SSO → configure
  auto-upload (disable photo auto-upload, Immich already handles that).

- [ ] **Install `user_oidc` app** in Nextcloud admin if the bootstrap Job's
  `occ app:install` step fails (it may need internet access from the pod — the
  alternative is to enable it from the Nextcloud app store UI once logged in as admin).

- [ ] Verify `cloud.apps.home.shdr.ch` resolves via the Cilium L2 VIP and
  the Caddy wildcard passes traffic through correctly.

---

## App Decisions: Final Keep / Kill / Migrate List

### Keep on Dokploy (no migration needed right now)

| App | Dokploy name | Key notes from compose audit |
|---|---|---|
| **Vaultwarden** | `default-vaultwarden-fuyfhc` | Sqlite volume. You have a Bitwarden export in Downloads. SIGNUPS_ALLOWED=true — change this. |
| **Karakeep** (was Hoarder) | `default-hoarder-xlt9m2` | Meilisearch + sqlite. Uses LiteLLM at `litellm.d.home.shdr.ch` — **update `OPENAI_BASE_URL` to `litellm.home.shdr.ch` since litellm.d is being killed**. |
| **BentoPDF** | `default-bentopdf-ksbpya` | Stateless. Also accessible at `pdf.shdr.ch` (behind oauth2-proxy). |
| **Hoppscotch** | `default-hoppscotch-atazkg` | Postgres bind-mounted at `../postgres_data`. Password `hoppscotchpass` is hardcoded in compose — **rotate during next redeploy**. `proxyscotch` is bundled in same stack. |
| **Perplexica** | `default-perplexica-1vcy9k` | Points to `searxng.home.shdr.ch` for search. Config at `../files/config.toml`. |
| **Affine** | `default-affine-ghfpkn` | PGVector postgres + Manticore indexer + Redis. Version pinned at `0.25.7`. 89 MB postgres. |
| **Dawarich** | `default-dawarich-x85obj` | Running `RAILS_ENV: development` with hardcoded `DATABASE_PASSWORD: password` — **fix before production use**. 118 MB postgres. |
| **Your-Spotify** | `default-yourspotify-xirzmz` | Mongo + server + client. Spotify API creds (`SPOTIFY_PUBLIC`, `SPOTIFY_SECRET`) embedded in compose — **move to .env**. 530 MB mongo. Note: orphan 301 MB mongo volume exists from old deploy. |
| **Memos** | `default-memos-ueso96` | Sqlite volume `memos_data` (no project suffix — rename risk if redeploy changes project). |
| **Mazanoke** | `default-mazanoke-lv71ic` | Stateless. |

### Migrate off Dokploy

| App | Destination | Status |
|---|---|---|
| **Immich** | Talos k8s | `tofu/home/kubernetes/immich.tf` built and committed (your WIP, not my commit). Needs: NFS share at `/mnt/hdd/data/immich` on smith, then apply. |
| **Nextcloud Drive** | Talos k8s | Built this session — see above. |

### Kill (data exported or stateless — safe to delete from Dokploy)

| App | Dokploy name | Data status |
|---|---|---|
| Homarr (`h.d`) | `default-homarr-1xh33s` | Config archived at `~/dokploy-archive/homarr-config.tgz`. **Kill after Grafana home is live.** |
| SilverBullet (notes) | `default-silverbullet-b4ahmt` | Markdown exported to `~/notes-export/`. Safe to delete. |
| FreshRSS | `default-freshrss-yzxwwi` | Sqlite archived at `~/dokploy-archive/freshrss.tgz`. OPML extractable via `sqlite3`. |
| Mermaid | `default-mermaid-z7wx7u` | Stateless. No data. |
| IT Tools | `default-ittools-qf9cko` | Stateless. No data. |
| Speedtest Tracker | `default-speedtest-tracker-k8htdf` | Tiny sqlite. You decided to skip backup. |
| LibreChat (`chat.d`) | `default-librechat-afq965` | 480 MB mongo. You decided to skip backup. |
| n8n | `default-n8n-kwglu9` | 11 MB data. You decided to skip backup (IaC, not workflows). |
| Windmill | `default-windmill-yp2hjx` | 108 MB postgres + caches. You decided to skip backup. |
| Baserow | `default-baserow-or99hz` | 381 MB. You decided to skip backup. |
| Huly | `default-huly-xntwoq` | 347 MB. You decided to skip backup. |
| Plane | `default-plane-hxnauo` | 74 MB. You decided to skip backup. |
| Dify | `default-dify-kbixfx` | 794 MB plugin storage. You decided to skip backup. |
| Drawio | `default-drawio-w9njeh` | Font volume only — stateless effectively. |
| OnlyOffice Document Server | `default-onlyoficedocumentserver-cfopky` | Stateless. Delete after k8s OnlyOffice is verified with Nextcloud. |
| Existing Nextcloud | `default-nextcloudaio-yuyvls` | User files exported to `~/nextcloud-export/`. **Delete only after new k8s Nextcloud is verified.** |
| Coder | `default-coder-spjt46` | Workspace home archived at `~/dokploy-archive/coder-workspace.tgz`. |
| OpenHands | `default-openhands-dktjmf` | 16 KB. No data worth saving. |
| SilverBullet old | `default-silverbullet-b4ahmt` | Same stack as notes above — one delete. |
| SurrealDB | `default-surrealdb-lvy52u` | Stateless for your usage. |
| Jellyfin (dokploy) | `default-jellyfin-evz0an` | Duplicate of media-stack Jellyfin. 856 MB config. Verify no unique playlists/users before deleting. |
| Threadfin | `default-threadfin-zca2sa` | IPTV. Check if media-stack covers this. |
| TVHeadend | `default-tvheadend-oysxps` | IPTV. Same. |
| M3UProxy | `default-m3uproxy-iweurc` | IPTV. Same. |
| Seafile | `default-seafile-xb6dgf` + `default-seafile-2qzcvw` | 1.6 MB — effectively empty. Two stacks, both dead. |

### Pending your decision (do NOT delete without resolution)

| App | Issue |
|---|---|
| `osemu-and-ehis-farms-wordpress-vpsun3` | **Family/farm WordPress site. 670 MB. Confirm with the family before any action.** |
| `osemu-and-ehis-farms-garagewithui-*` | Same family project. Confirm before delete. |
| OneDev | `default-onedev-j4jf4j` — 194 MB of self-hosted Git repos. **Verify all repos exist on GitLab before deleting.** |

---

## Orphan Docker Volumes to Clean Up

These are leftover from previous deploys on the dokploy VM and can be removed
with `docker volume rm <name>` once the new deploys are stable:

| Orphan volume | Size | Note |
|---|---|---|
| `default-yourspotify-xirzmz_mongo_data` | 301 MB | Old deploy; active volume has `-default-yourspotify-xirzmz` suffix |
| `default-dawarich-x85obj_dawarich_db_data` | 108 MB | Same pattern — old deploy |
| `default-dawarich-x85obj_dawarich_shared` | — | Old deploy |
| `default-seafile-2qzcvw_*` | 588 KB | Second seafile stack |

---

## Key Settings Issues Found (Fix Before Production)

These were found by reading the live compose files from the disk — fix them
whenever you next redeploy the affected app:

1. **Karakeep** — `OPENAI_BASE_URL` still points to `litellm.d.home.shdr.ch`
   (a Dokploy service being killed). Update to `https://litellm.home.shdr.ch/v1`.

2. **Vaultwarden** — `SIGNUPS_ALLOWED=true` in prod. Should be `false`.

3. **Dawarich** — Running `RAILS_ENV: development` with plain `DATABASE_PASSWORD: password`.
   Neither is appropriate for production. Fix both in the env before the next
   restart.

4. **Hoppscotch** — `POSTGRES_PASSWORD: hoppscotchpass` hardcoded in compose
   (not in `.env`). Move to `.env` and rotate on next redeploy.

5. **Your-Spotify** — `SPOTIFY_PUBLIC` and `SPOTIFY_SECRET` embedded inline in
   `docker-compose.yml`. Move to `.env`.

6. **OnlyOffice** — old Dokploy stack has
   `JWT_SECRET=aG0afpTMkjgfXaIXj7q5U3L8itP8s9TB` hardcoded inline. The k8s
   replacement generates a new Tofu-managed JWT secret; delete the old stack
   only after Nextcloud Office is verified.

---

## Remaining IaC Work (Not Yet Built)

### High priority

- [x] **OnlyOffice Document Server** (`tofu/home/kubernetes/onlyoffice.tf`) —
  office editing inside Nextcloud. Run as a separate Deployment in the
  `nextcloud` namespace, expose `onlyoffice.apps.home.shdr.ch`, and configure
  Nextcloud with the `onlyoffice` connector app + JWT.

- [x] **Grafana home dashboard** (`ansible/playbooks/monitoring_stack/grafana/
  provisioning/dashboards/home.json`) — Dokploy traffic tiles added for each
  audited app host. Tiles query
  `caddy_http_response_size_bytes_sum{host=~"..."}`, show sparklines, and link
  directly to the app.

- [x] **Caddy `home.shdr.ch` route** — placeholder response replaced with a
  redirect to `https://grafana.home.shdr.ch/d/home/home`.

### Medium priority (keep-app data backups before any redeploy)

Before migrating or redeploying any kept Dokploy app, snapshot its data first.
Same RBD snapshot method used this session works. Volumes to capture:

| App | Volumes to snapshot |
|---|---|
| Karakeep | `data-default-hoarder-xlt9m2`, `meilisearch-default-hoarder-xlt9m2` |
| Affine | `affine_uploads-*`, `affine_db-*`, `affine_indexer-*`, `../files/config.json` |
| Dawarich | `dawarich_db_data-default-dawarich-x85obj`, `dawarich_storage-*`, `dawarich_watched-*` |
| Your-Spotify | `mongo_data-default-yourspotify-xirzmz` (the active 530 MB one) |
| Hoppscotch | `../postgres_data` bind mount |
| Memos | `memos_data` volume |

### Lower priority

- [ ] Fix Dokploy SSH access — the `aether` user on 10.0.3.6 does not accept your
  current Mac pubkey or the Step-CA cert. Root cause: the VM was provisioned with
  a different `var.authorized_keys`. Fix: add current pubkey via Proxmox console
  (`qm terminal 1005`), or add `TrustedUserCAKeys` to sshd_config via Ansible
  once SSH is working.

- [ ] Sweep all Fedora cloud-init VMs for SSH key consistency — gateway accepts
  your key, dokploy does not. Other VMs may have the same drift.

---

## Infrastructure Reference

| Service | Address | Auth |
|---|---|---|
| Proxmox web UI | `niobe/trinity/oracle/smith/neo.home.shdr.ch:8006` | proxmox admin |
| Dokploy VM | `10.0.3.6` | SSH broken (see above); Proxmox console via trinity |
| Dokploy web UI | `d.home.shdr.ch` | Dokploy admin |
| Traefik (Dokploy) | `traefik.d.home.shdr.ch` | no auth |
| Ceph RGW S3 | `s3.home.shdr.ch` (LB: trinity/smith/neo 7480) | RGW user creds |
| Keycloak | `auth.shdr.ch/realms/aether` | admin |
| OpenBao | `bao.home.shdr.ch` | Keycloak SSO |
| Monitoring (Grafana) | `grafana.home.shdr.ch` | Keycloak SSO |
| Loki | `10.0.2.3:3100` (LAN only, monitoring-stack VM) | none (no auth_enabled) |
| Prometheus | `10.0.2.3:9090` (LAN only) | none |
| New Nextcloud | `cloud.apps.home.shdr.ch` (after apply) | Keycloak SSO |
| New OnlyOffice | `onlyoffice.apps.home.shdr.ch` (after apply) | Nextcloud connector + JWT |

### Key cluster facts

- Talos cluster: `aether-k8s`
- API VIP: `10.0.3.20`
- Workload VIP (Cilium L2): `10.0.3.19` — all `*.apps.home.shdr.ch` traffic lands here
- Nodes: talos-trinity/neo/niobe (CP+worker), talos-smith (worker+GPU GTX 1660), talos-mouse (ARM Pi)
- GPU nodes: neo (RTX Pro 6000, primary ML), smith (GTX 1660 Super, secondary)
- Storage classes: `ceph-rbd` (default for PVCs), `nfs-hdd` (large media on smith NFS LXC)

---

## Branch State

```
main
 └── migration/nextcloud-k8s  ← current working branch
      └── 554735a  Add Nextcloud Drive to Talos k8s (S3-backed, Keycloak SSO)
```

Your WIP changes (unstaged on this branch, not committed by me):
- `tofu/home/kubernetes/immich.tf` — Immich k8s migration
- `tofu/home/kubernetes/oidc_discovery.tf` — k8s OIDC public discovery
- `tofu/home/kubernetes/onlyoffice.tf` — OnlyOffice Document Server for Nextcloud Office
- `ansible/playbooks/monitoring_stack/grafana/provisioning/dashboards/home.json` — Grafana home WIP
- `ansible/playbooks/home_gateway_stack/caddy/Caddyfile.j2` — new routes WIP
- `ansible/playbooks/monitoring_stack/site.yml` — monitoring changes
- Various other `tofu/home/` file tweaks (`ha.tf`, `backup_stack.tf`, etc.)

These are yours — commit them separately when ready.

---

## Suggested Order of Operations

1. **Now**: Add/confirm sops secrets, run RGW Ansible play, `tofu apply` → Nextcloud + OnlyOffice live
2. **After Nextcloud verified**: Kill old `default-nextcloudaio-yuyvls` from Dokploy
3. **After Nextcloud mobile tested**: Verify Nextcloud Office can create/edit docs via OnlyOffice
4. **In parallel**: Commit your Immich + Grafana home WIP, apply, test
5. **After Grafana home live**: Kill Homarr (`default-homarr-1xh33s`)
6. **Then**: Work through the kill list — stateless apps first (mermaid, it-tools,
   drawio, LibreChat, n8n, windmill, baserow, huly, plane, dify, coder, openhands),
   then the IPTV cluster (threadfin/tvheadend/m3uproxy — confirm they're unused),
   then the duplicate Jellyfin
7. **Last**: Resolve oefarms/OneDev before touching those
8. **Ongoing**: Fix Dawarich RAILS_ENV, Hoppscotch password, Karakeep LiteLLM URL,
   Vaultwarden signups when each app is next redeployed
