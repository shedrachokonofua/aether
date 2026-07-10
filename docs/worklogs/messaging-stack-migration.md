# Messaging Stack Migration

Move Matrix off the `messaging-stack` VM (`vmid 1016`, `10.0.3.4`, fedora +
rootless podman quadlets) to k8s, then rename the slimmed-down VM to
`notifications-stack` on VLAN 2. Originally a two-phase plan agreed during the
2026-05-03 session (Phase 2 then meant a new NixOS VM); Phase 2 revised
2026-06-11 to a rename-in-place — the VM is **not** decommissioned:

- **Phase 1 — Matrix → Talos k8s** (this worklog covers the IaC + decommission).
  Synapse + element + the two mautrix bridges + their postgres land in a new
  `matrix` namespace, modelled on `miniflux.tf`. Same per-app `tofu apply` →
  RBD-snapshot → decommission playbook → `kubectl cp` restore → Caddy flip
  pattern that worked for the media-stack migration in
  [media-stack-migration.md](./media-stack-migration.md).
- **Phase 2 — rename the VM to `notifications-stack` and move it to VLAN 2**
  (revised 2026-06-11; replaces the original "build a new NixOS VM" plan).
  ntfy + postfix + apprise stay exactly where they are, running as podman
  quadlets on the existing VM. After Matrix leaves in Phase 1, the VM is
  renamed in place (keeps vmid `1016`) and re-IP'd to `10.0.2.4`/VLAN 2 —
  the slot previously reserved for the never-built NixOS VM (vmid `1011`,
  which gets dropped). No new host, no notification gap, no NixOS
  prerequisite. A NixOS conversion of this VM can still happen later as its
  own phase in `docs/nixos.md`, decoupled from this migration.

`hermes-bots` is **already on k8s** in the `infra` namespace (`hermes.tf`); it
talks to `https://matrix.home.shdr.ch`, so as long as the Caddy backend swap
keeps that hostname valid it is unaffected by Phase 1.

---

## Source paths on messaging-stack VM

All quadlets run as user `aether`. Everything is inside one podman pod
(`matrix.pod`) for the Matrix side; ntfy/postfix/apprise are independent pods.

| App | Container data | Notes |
|---|---|---|
| synapse | `/home/aether/synapse/data` (media_store, signing key, logs) | port 8008, metrics 9091 |
| postgres (matrix pod) | named volume `synapse_postgres_storage` | hosts `synapse`, `mautrix_whatsapp`, `mautrix_gmessages` DBs |
| element | `/home/aether/element/config` | port 8080 |
| mautrix-whatsapp | `/home/aether/mautrix-whatsapp/data` | config.yaml, registration.yaml, sqlite cache (not used — points at PG) |
| mautrix-gmessages | `/home/aether/mautrix-gmessages/data` | same |
| ntfy | `/home/aether/ntfy/{config,data}` + volume `ntfy_cache` | Phase 2 |
| postfix | volume `postfix_queue` | SES relay; Phase 2 |
| apprise | `/home/aether/apprise/config` | Phase 2 |

Caddy currently routes (`ansible/playbooks/home_gateway_stack/caddy/Caddyfile.j2`):

```caddy
element.home.shdr.ch  →  {{ vm.messaging_stack.ip }}:8080
matrix.home.shdr.ch    /_matrix/*          → {{ vm.messaging_stack.ip }}:8008
                       /_synapse/client/*  → {{ vm.messaging_stack.ip }}:8008
ntfy.home.shdr.ch     →  {{ vm.messaging_stack.ip }}:8082
apprise.home.shdr.ch  →  {{ vm.messaging_stack.ip }}:8000
```

Keycloak SMTP relay (`tofu/home/keycloak.tf:106` and
`tofu/home/keycloak_seven30.tf:37`) points at `messaging_stack.ip:25`, and
GitLab (`ansible/playbooks/gitlab/gitlab.rb.j2:22`) at the same relay. Both
re-point during the Phase 2 rename/re-IP — see the cutover order there.

---

## Phase 1 — Matrix to k8s

### Architecture (k8s side)

One namespace `matrix`. Following the cluster convention (newest example:
`miniflux.tf` — separate StatefulSet for postgres), but the application side
keeps **synapse, element, and the two bridges in a single Deployment with
multiple containers**, mirroring the existing `matrix.pod` podman layout. The
reason is shared registration files: bridges write
`/data/registration.yaml`, and synapse needs to read those paths via
`app_service_config_files`. RWO Ceph-RBD PVCs can be mounted into multiple
containers within the same Pod, so we mount each bridge's data PVC `ro` into
synapse at `/srv/<bridge>/`.

| Resource | Shape | Why |
|---|---|---|
| `kubernetes_namespace_v1.matrix` | — | new |
| `kubernetes_stateful_set_v1.matrix_postgres` | 1 replica, RBD PVC, init ConfigMap | cluster convention; init script creates the two bridge DBs on a fresh volume |
| `kubernetes_deployment_v1.matrix` | replicas=1, strategy=Recreate, 4 containers | synapse + element + mautrix-whatsapp + mautrix-gmessages |
| `kubernetes_persistent_volume_claim_v1.synapse_data` | RBD, 20Gi, `prevent_destroy` | media_store + runtime files |
| `kubernetes_persistent_volume_claim_v1.matrix_postgres_data` | RBD, 10Gi, `prevent_destroy` | postgres data |
| `kubernetes_persistent_volume_claim_v1.mautrix_whatsapp_data` | RBD, 5Gi, `prevent_destroy` | bridge state + registration.yaml |
| `kubernetes_persistent_volume_claim_v1.mautrix_gmessages_data` | RBD, 5Gi, `prevent_destroy` | same |
| `kubernetes_config_map_v1.synapse_config` | homeserver.yaml + log.config | rendered from `.tftpl` |
| `kubernetes_config_map_v1.element_config` | config.json | rendered from `.tftpl` |
| `kubernetes_config_map_v1.matrix_postgres_init` | init-bridge-dbs.sql | mounted at `/docker-entrypoint-initdb.d/` |
| `kubernetes_secret_v1.synapse_secrets` | signing key + doublepuppet.yaml | mounted as files |
| `kubernetes_secret_v1.matrix_postgres` | POSTGRES_USER/PASSWORD/DB | env_from on postgres SS |
| `kubernetes_service_v1.synapse` | port 8008 | client/server |
| `kubernetes_service_v1.element` | port 8080 | element-web |
| `kubernetes_service_v1.matrix_postgres` | port 5432, ClusterIP | for synapse + bridges |
| `kubernetes_manifest.matrix_route` | HTTPRoute `matrix.home.shdr.ch`, path-prefix `/_matrix` + `/_synapse/client` | preserves Caddy's path-filtering (admin API stays off the wire) |
| `kubernetes_manifest.element_route` | HTTPRoute `element.home.shdr.ch` | — |

**Synapse container mount layout** (intentional move away from "everything in `/data`"):

| Mount | Source | Why |
|---|---|---|
| `/etc/synapse/homeserver.yaml` (subPath) | `synapse-config` CM | rendered from template |
| `/etc/synapse/matrix.home.shdr.ch.log.config` (subPath) | `synapse-config` CM | static |
| `/etc/synapse/doublepuppet.yaml` (subPath) | `synapse-secrets` Secret | contains AS tokens |
| `/etc/synapse/matrix.home.shdr.ch.signing.key` (subPath) | `synapse-secrets` Secret | — |
| `/srv/whatsapp/registration.yaml` (subPath, ro) | `mautrix-whatsapp-data` PVC | written by bridge container |
| `/srv/gmessages/registration.yaml` (subPath, ro) | `mautrix-gmessages-data` PVC | same |
| `/data` (rw) | `synapse-data` PVC | media_store only |

`SYNAPSE_CONFIG_PATH=/etc/synapse/homeserver.yaml` to override the default
`/data/homeserver.yaml` lookup.

Database connection: bridges and synapse all connect to
`matrix-postgres.matrix.svc.cluster.local:5432`, not localhost. Each uses its
own DB on the same postgres instance.

### Bridge config caveat

The mautrix bridge configs are hundreds of lines and the bridge writes back to
them at runtime. Phase 1 punts on rendering them from `.tftpl`: the bridge
PVCs come up empty, and the **migration restore drops in the bridge's existing
config.yaml + registration.yaml + sqlite cache from the tarball.** A
**fresh-from-zero deployment will not work until** a follow-up adds initContainer
seeding of the bridge configs from a ConfigMap (tracked as a TODO at the bottom
of this file). The synapse side is fine — homeserver.yaml is fully rendered
from a template.

### Data migration

Postgres uses `pg_dump --format=custom` per database (not `pg_dumpall`)
because the k8s side's init script will have already created empty DBs by the
time we restore — per-DB restore avoids `CREATE DATABASE` collisions.

```
synapse data  →  /tmp/messaging-stack-export/synapse-data.tar.gz     (no postgres data)
postgres      →  /tmp/messaging-stack-export/{synapse,whatsapp,gmessages}.dump
whatsapp data →  /tmp/messaging-stack-export/mautrix-whatsapp-data.tar.gz
gmessages data → /tmp/messaging-stack-export/mautrix-gmessages-data.tar.gz
```

### Order of operations

1. **Worklog + IaC drafted, reviewed, committed.** (don't apply yet)
2. **RBD snapshot of vm-1016 disk** as the safety belt (same recipe as media-stack):
   ```bash
   # on trinity, root
   SNAP=pre-matrix-migrate-$(date +%s)
   rbd snap create vm-disks/vm-1016-disk-0@${SNAP}
   rbd snap protect vm-disks/vm-1016-disk-0@${SNAP}
   ```
3. **`task tofu:apply`** in `tofu/home/`. New `matrix` namespace +
   `matrix-postgres` StatefulSet come up (postgres is happy with an empty
   volume — the init ConfigMap creates the bridge DBs). The `matrix`
   Deployment Pod **will crash-loop** on first start (bridges have no
   `config.yaml`, synapse has no AS `registration.yaml`) — **expected**.
   Immediately scale the Deployment to 0 so the restore Pod can attach the
   PVCs:
   ```bash
   kubectl -n matrix scale deployment/matrix --replicas=0
   kubectl -n matrix wait --for=delete pod -l app=matrix --timeout=2m
   ```
4. **Decommission playbook**:
   ```bash
   task ansible:playbook -- ./ansible/playbooks/messaging_stack/decommission_matrix.yml
   ```
   Stops the `matrix-pod` user-scope quadlet, runs `pg_dump` per DB, tars
   synapse + bridge data dirs, fetches everything to local
   `/tmp/messaging-stack-export/`.
5. **Restore postgres** directly into the running `matrix-postgres-0`
   (postgres is the only k8s-side container that's actually Running). Per-DB
   `pg_restore --clean --if-exists` to avoid `CREATE DATABASE` collisions
   with the init script's pre-created DBs:
   ```bash
   DB_USER=$(kubectl -n matrix get secret matrix-postgres -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
   for db in synapse:$DB_USER mautrix_whatsapp:mautrix_whatsapp mautrix_gmessages:mautrix_gmessages; do
     src=${db%%:*}; dst=${db##*:}
     kubectl -n matrix cp /tmp/messaging-stack-export/${src}.dump matrix-postgres-0:/tmp/
     kubectl -n matrix exec matrix-postgres-0 -- \
       pg_restore --clean --if-exists -U "$DB_USER" -d "$dst" /tmp/${src}.dump
   done
   ```
6. **Restore PVC contents via a one-shot restore Pod.** RWO PVCs can only
   attach to one Pod at a time; the matrix Deployment is scaled to 0, so the
   PVCs are free. Spin up `matrix-restore` with all three PVCs mounted, `cp`
   + `tar xzf` each tarball, then delete:
   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: matrix-restore
     namespace: matrix
   spec:
     restartPolicy: Never
     containers:
       - name: restore
         image: alpine:latest
         command: ["sleep", "3600"]
         volumeMounts:
           - { name: synapse-data,           mountPath: /restore/synapse }
           - { name: mautrix-whatsapp-data,  mountPath: /restore/whatsapp }
           - { name: mautrix-gmessages-data, mountPath: /restore/gmessages }
     volumes:
       - { name: synapse-data,           persistentVolumeClaim: { claimName: synapse-data } }
       - { name: mautrix-whatsapp-data,  persistentVolumeClaim: { claimName: mautrix-whatsapp-data } }
       - { name: mautrix-gmessages-data, persistentVolumeClaim: { claimName: mautrix-gmessages-data } }
   EOF
   kubectl -n matrix wait --for=condition=Ready pod/matrix-restore --timeout=2m

   # synapse: only extract media_store/ — homeserver.yaml, signing.key, log
   # config now come from ConfigMap/Secret in /etc/synapse, so don't shadow
   # them with legacy files from /data.
   kubectl -n matrix cp /tmp/messaging-stack-export/synapse-data.tar.gz matrix/matrix-restore:/tmp/
   kubectl -n matrix exec matrix-restore -- sh -c '\
     mkdir -p /restore/synapse/media_store && \
     tar xzf /tmp/synapse-data.tar.gz -C /tmp/ && \
     cp -a /tmp/data/media_store/. /restore/synapse/media_store/ && \
     rm -rf /tmp/data /tmp/synapse-data.tar.gz'

   # whatsapp + gmessages bridges: restore the whole /data dir (brings
   # config.yaml + registration.yaml + sqlite cache).
   for b in whatsapp gmessages; do
     kubectl -n matrix cp /tmp/messaging-stack-export/mautrix-${b}-data.tar.gz matrix/matrix-restore:/tmp/
     kubectl -n matrix exec matrix-restore -- sh -c "\
       tar xzf /tmp/mautrix-${b}-data.tar.gz -C /restore/${b} --strip-components=1 && \
       rm -f /tmp/mautrix-${b}-data.tar.gz"
   done

   kubectl -n matrix delete pod matrix-restore
   ```
7. **Scale matrix Deployment back up** — synapse now sees the AS
   registration files at `/srv/{whatsapp,gmessages}/registration.yaml` via
   the bridge PVCs; bridges find their `config.yaml` in `/data`:
   ```bash
   kubectl -n matrix scale deployment/matrix --replicas=1
   kubectl -n matrix rollout status deployment/matrix --timeout=5m
   ```
8. **Verify**:
   - `kubectl -n matrix logs deploy/matrix -c synapse | grep -i ready`
   - `curl -k http://<synapse-clusterIP>:8008/_matrix/client/versions` returns 200
   - whatsapp/gmessages bridges connect (look for "Connected to WhatsApp" / "Connected to Google Messages" in their container logs)
   - hermes-bots in the `infra` namespace still reach matrix (`kubectl -n infra logs deploy/hermes-beryl --tail=50` shows no auth errors)
9. **Flip Caddy** — edit `ansible/playbooks/home_gateway_stack/caddy/Caddyfile.j2`
   so `matrix.home.shdr.ch` and `element.home.shdr.ch` point at the cluster
   Gateway VIP (`var.workload_vip`, same as the media stack flip). Apply:
   ```bash
   task configure:caddy
   ```
10. **Smoke test from outside** — Element web client at `https://element.home.shdr.ch`
    logs in, rooms list, bridge bots are present. Send a test WhatsApp + Google
    Messages message both directions.
11. **Sweep the VM-side definitions**:
    - Delete `matrix.yml` from `ansible/playbooks/messaging_stack/`
    - Drop the `import_playbook: matrix.yml` line from `messaging_stack/site.yml`
    - Drop synapse scrape from the `vm_monitoring_agent` block in `site.yml`
    - Re-run `task configure:notifications-stack` so monitoring-agent forgets the
      stale targets and `matrix-pod` quadlet files are gone
12. **Drop the RBD snapshot** once you're satisfied (~1 week of soak):
    ```bash
    rbd snap unprotect vm-disks/vm-1016-disk-0@${SNAP}
    rbd snap rm       vm-disks/vm-1016-disk-0@${SNAP}
    ```

### Gotchas to watch

- **First-apply deadlock — restore Pod is mandatory, not optional.** Synapse
  refuses to start when `app_service_config_files` paths are empty/missing;
  bridges refuse to start without `config.yaml`. So the Pod crash-loops on
  initial deploy, and `kubectl cp` against a CrashLoopBackOff container
  fails. The PVCs are RWO, so we can't attach a second restore Pod while the
  main Deployment Pod (terminating/restarting) still holds them. Hence step
  3: scale Deployment to 0, wait for Pod delete, only then create
  `matrix-restore`.
- **Pod = single restart unit.** Any of the 4 containers crashing cycles all
  4 — bridges' lifecycle is coupled to synapse. If a bridge's `livenessProbe`
  starts flapping, it takes synapse with it. Start with no liveness probes on
  the bridges (only readiness); revisit after a week.
- **Bridge registration files are bridge-managed.** First start of a bridge
  with no `registration.yaml` causes the bridge image's entrypoint to
  generate one. In current podman flow this is a separate `podman run --rm`
  step done by ansible. In k8s we rely on the migration restoring an existing
  file. If the file is missing on restore, the bridge will hot-generate one
  on start — but synapse won't know about it until the file appears and
  synapse is restarted. **If you ever destroy a bridge PVC, restart synapse
  after the bridge regenerates its registration.**
- **media_store path change.** Existing podman layout had `media_store` at
  `/data/media_store`; k8s keeps that path (synapse-data PVC mounted at `/data`).
  No URL changes.
- **Database `dbname == user`** in the current setup (`secrets.matrix.database_user`
  is used as both). Don't change that or the restore breaks. The init script
  creates the bridge DBs with the same owner.
- **Element CORS.** Element web reads `config.json` at runtime; the base_url
  is `https://matrix.home.shdr.ch` and stays the same across the cutover.
  Browsers caching the old config.json is harmless.
- **Hermes bots in `infra` ns.** They use `MATRIX_USER_ID` like
  `@beryl:matrix.home.shdr.ch` with bot access tokens stored in
  `var.secrets["matrix.<name>_bot_access_token"]`. These tokens were issued
  by the existing Synapse, so they survive the migration intact as long as
  the postgres `access_tokens` table is fully restored (it will be, via the
  per-DB dump).
- **Postgres image version**. Source VM runs `postgres:alpine` (no pin),
  which by now is 18.x. The k8s side pins `postgres:17-alpine` to match the
  cluster convention. `pg_restore` from a newer dump into an older server
  fails — check the source server version first:
  ```bash
  ssh aether@10.0.3.4 'podman exec postgres pg_dumpall --version'
  ```
  If it reports 18.x, bump the k8s pin to `postgres:18-alpine` **before**
  running `tofu apply` (matrix.tf, `matrix_postgres_image` local).

---

## Phase 1 — execution notes (2026-06-11, done)

Executed end-to-end on 2026-06-11. Postgres on the VM was 17.6 → the
`postgres:17-alpine` pin was correct as-is. RBD safety snapshot:
`vm-disks/vm-1016-disk-0@pre-matrix-migrate-1781224510` (protected — drop
after ~1 week of soak). Deviations and discoveries, in case the next
migration rhymes:

1. **decommission_matrix.yml had two latent bugs** (fixed in-tree):
   it read `secrets.*` from the inventory var (the *raw* sops file — must
   `community.sops.load_vars` in standalone playbooks), and the
   `podman cp` task had `become: true`, which switches to root's podman
   namespace where the rootless containers don't exist.
2. **Schema pollution from the pre-restore crash-loop.** The initial
   crash-looping synapse ran current-version migrations against the empty
   DB before dying. `pg_restore --clean` only drops objects present in the
   dump, so newer tables (e.g. `sticky_events`) survived and synapse then
   crashed on migration replay (`DuplicateTable`). Fix: scale to 0, DROP +
   recreate the synapse DB (`TEMPLATE template0 LC_COLLATE 'C'`), restore
   into the virgin DB. Bridges were unaffected (they never reached their
   DBs pre-restore).
3. **kubelet subPath artifacts on the bridge PVCs.** The crash-looping pod's
   `subPath: registration.yaml` mounts auto-created empty *directories*
   named `registration.yaml` on both bridge PVCs, which broke the tar
   extraction. `rmdir` them before extracting.
4. **Bridge config.yaml needed a DB URI rewrite.** On the VM everything
   shared one podman pod network, so configs said `@localhost/`. Patched to
   `@matrix-postgres/` on the PVCs. The homeserver (`localhost:8008`) and
   appservice (`localhost:29318/29336`) addresses stay correct — those
   containers share the k8s Pod.
5. **Duplicate `Server` header broke hermes.** Caddy → Envoy(gateway) →
   synapse yields `Server: Caddy` + `server: envoy`; hermes' aiohttp
   rejects the response with 400. Fixed with `header_down -Server` in the
   `*.home.shdr.ch` wildcard block (and the `ha.home.shdr.ch` block, which
   had the same pre-existing issue with HA's own Server header).

Still pending after verification soak: rerun
`decommission_matrix.yml -e cleanup=true` (disables the matrix-pod quadlet
and deletes legacy app dirs on the VM), and drop the RBD snapshot.

---

## Phase 2 — rename to notifications-stack, move to VLAN 2

**Not started. Run only after Phase 1 is green** — Matrix still routes to this
VM's IP until the Caddy flip, so the rename/re-IP must not happen first.

Plan (revised 2026-06-11): the existing VM (vmid `1016`) is kept and renamed
in place. ntfy/postfix/apprise keep running as-is; only the VM's identity and
network placement change: `messaging-stack` `10.0.3.4`/VLAN 3 →
`notifications-stack` `10.0.2.4`/VLAN 2 (Infrastructure — same VLAN as
monitoring-stack, where a notification relay belongs). The original plan to
build a fresh NixOS VM at vmid `1011` is dropped; that reservation is freed.

### Who consumes this VM (verified 2026-06-11)

| Consumer | Path | Affected by re-IP? |
|---|---|---|
| Keycloak (`10.0.2.8`, V2) | direct IP `:25` via `keycloak.tf:106`, `keycloak_seven30.tf:37` | Re-renders from the renamed vm.yml key; V2→V2, no firewall change |
| GitLab (`10.0.3.7`, V3) | direct IP `:25` via `gitlab.rb.j2:22` | **Yes — V3→V2 is default-drop.** Needs a new firewall rule (below) |
| Grafana alerting (`10.0.2.3`, V2) | `https://apprise.home.shdr.ch` via Caddy | No — Caddy (`10.0.2.2`, V2) → V2 |
| k8s pods / everything else | `ntfy.home.shdr.ch` / `apprise.home.shdr.ch` via Caddy | No — V3→Caddy:443 already allowed (`SERVICES-to-TRUSTED` rule 20) |

### Changes, in one commit

1. **`config/vm.yml`** — delete the reserved `notifications_stack:` block
   (vmid 1011). Rename the `messaging_stack:` key → `notifications_stack:`,
   set `name: "notifications-stack"`, `ip: "10.0.2.4"`, `gateway: "10.0.2.1"`.
   Drop the Matrix ports (synapse, synapse_metrics, element, whatsapp,
   gmessages, matrix_pg); keep `ntfy: 8082`, `ntfy_metrics: 9092`, `smtp: 25`,
   `postfix_metrics: 9154`, `apprise: 8000` (ports don't change — the quadlets
   are untouched).
2. **`tofu/home/messaging_stack.tf` → `notifications_stack.tf`** — rename the
   four resources (`proxmox_virtual_environment_vm.messaging_stack`,
   `random_password.messaging_stack_console_password`,
   `module.messaging_stack_user`,
   `proxmox_virtual_environment_haresource.messaging_stack`) and **add a
   `moved` block for each** — without them the plan shows destroy+create,
   which `prevent_destroy = true` will refuse. Change `network_device.vlan_id`
   `3 → 2`; the `ip_config` picks up the new IP from vm.yml. The provider
   updates the cloud-init drive; the VM needs a reboot to take the new
   address. Guest-internal hostname stays `messaging-stack` (user-data is in
   `ignore_changes`) — fix manually with `hostnamectl` if it bothers you,
   it's cosmetic.
3. **Router** (`ansible/playbooks/home_router/configure_router.yml`) — add a
   `SERVICES-to-TRUSTED` rule (next free: 24) allowing tcp/25 from
   `{{ vm.gitlab.ip }}` to `{{ vm.notifications_stack.ip }}`, description
   'Allow SMTP from GitLab to notifications relay'.
4. **`ansible/playbooks/gitlab/gitlab.rb.j2:22`** — `vm.messaging_stack.*` →
   `vm.notifications_stack.*`.
5. **`tofu/home/keycloak.tf` + `keycloak_seven30.tf`** — same key rename.
6. **`ansible/inventory/hosts.yml`** — rename the `messaging-stack` host
   entry (IP resolves from vm.yml).
7. **`ansible/playbooks/messaging_stack/` → `notifications_stack/`** — drop
   `matrix.yml` from `site.yml` (Phase 1 sweep should already have done
   this), rename the dir, update the Taskfile targets
   (`Taskfile.yml:326-329`: `configure:messaging-stack` and
   `configure:messaging` → `configure:notifications-stack` /
   `configure:notifications`).
8. **Fleet playbook host lists** — rename `messaging-stack` in
   `ansible/playbooks/upgrade_fedora_vms.yml:5` and
   `ansible/playbooks/setup_vm_monitoring_agents.yml:9`.
8b. **AdGuard DNS rewrite** — `nix/hosts/common/adguard-resolver.nix:158`
   pins `smtp.home.shdr.ch → 10.0.3.4` (found 2026-06-11; IP-based, so the
   name-grep sweep missed it). Update to `10.0.2.4` and redeploy both
   AdGuard LXCs. Check who uses `smtp.home.shdr.ch` vs the raw IP while
   you're there.
9. **Monitoring sweep** — `vm_monitoring_agent` / prometheus targets pick up
   the renamed inventory host; re-run the monitoring playbook so labels and
   scrape targets follow.

Verified 2026-06-11: a full-repo grep for `messaging_stack|messaging-stack`
turns up nothing beyond the files above plus comments in
`tofu/home/kubernetes/matrix.tf` (historical context, no action) and the
`ansible/playbooks/messaging_stack/` dir itself. Grafana has **no** SMTP
config — alerting goes exclusively through the apprise contact points, so no
Grafana change is needed. Keycloak's only references are the two `smtp_server`
blocks (`keycloak.tf:106`, `keycloak_seven30.tf:37`), both reading
`local.vm.messaging_stack.*` — the vm.yml key rename re-points them.

### Cutover order (brief notification outage, acceptable)

1. `task tofu:apply` — VM NIC re-tags to VLAN 2, cloud-init IP updates,
   Keycloak SMTP re-points (same apply, so no email gap window).
2. Reboot the VM; confirm it's up on `10.0.2.4`.
3. Run the router playbook (GitLab SMTP rule).
4. Re-render Caddy (`home_gateway_stack`) — ntfy/apprise upstreams follow the
   renamed key.
5. Re-run the gitlab playbook (smtp_address) and the monitoring playbook.
6. Smoke test: `ntfy.home.shdr.ch` publish, apprise notify from Grafana test
   alert, password-reset email from Keycloak, test email from GitLab admin.

The VM is **not** decommissioned — it lives on as notifications-stack. If it
ever moves to NixOS, that's a standalone phase in `docs/nixos.md` using the
now-proven LXC/VM pattern from the AdGuard migration.

### Phase 2 — execution notes (2026-06-11, done)

Executed same-day after Phase 1. Two surprises:

1. **The reserved `10.0.2.4` was double-booked.** `vm.nfs.ip.vyos` (the NFS
   LXC's VLAN-2 leg) already held it — discovered when "the VM" answered
   SSH on the new IP with the wrong host key. Final IP is **`10.0.2.6`**.
   Lesson: validate reservations against every `ip:` in `config/vm.yml`,
   including nested per-network maps.
2. **Cloud-init can't re-apply network config on these Fedora VMs.** The
   fedora image's cloud-init was upgraded (via `upgrade_fedora_vms.yml`) to
   the single-process architecture where the per-stage systemd units are
   socket stubs for `cloud-init-main.service` — which the upgrade left
   **disabled**. ds-identify finds the NoCloud drive, the stage units
   "succeed", and nothing happens. So changing `ipconfig0` in tofu does
   nothing in-guest. Worked around by editing the NM profile directly
   (`nmcli con mod "cloud-init eth0" ...` + `hostnamectl set-hostname`,
   with a `systemd-run --on-active=8 nmcli con up` to survive the VLAN
   flip). Tofu's `ipconfig0` now matches guest reality, but any future
   re-IP of a fedora VM needs the same manual step (or enable
   `cloud-init-main` first).

Also fixed en route: the apprise → Matrix alert target
(`templates/apprise-config.yml.j2`) still pointed at the VM's synapse —
dead since Phase 1. Now `matrixs://…@matrix.home.shdr.ch` via the gateway.

---

## TODOs after Phase 1

- [ ] Render `mautrix-whatsapp` and `mautrix-gmessages` config.yaml as ConfigMaps
      with initContainer `cp -n` seeding to PVC, so the deployment is
      reproducible from zero (no manual tarball restore needed).
- [ ] Synapse `media_store` cleanup pass — the existing tarball will be the
      whole history. Worth checking size before restoring; if it's >5Gi, bump
      the PVC.
- [ ] Move hermes bot access tokens to a renewable flow (Keycloak OIDC?). The
      current static-token-in-secrets approach survives this migration but is
      fragile.
