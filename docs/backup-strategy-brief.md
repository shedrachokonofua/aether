# Backup Strategy Brief — aether

> Status: **IN PROGRESS**. Drafted 2026-06-21; partially implemented 2026-06-21.
> Grounded in repo inventory + live inspection of `neo`; items marked **[verify]** still need
> live confirmation before build.

## 0. Why this exists

The lab *intends* 3-2-1 but currently isn't there:

- **Everything local lives on `smith`** — bulk NFS data, the PBS datastore, (and the planned
  object store) — one chassis = one failure domain. Today's "3-2-1" is really *two copies in one
  box + a dead offsite*.
- **Offsite (restic→S3) was dead since 2026-01-08** (cert expired, renewal daemon dead,
  ~218k crash-loop restarts — diagnosed 2026-06-15). Fixed 2026-06-21 by reissuing the
  step-ca cert, moving renewal to a systemd timer, creating a fresh `restic-v2` repository, and
  verifying a smoke snapshot. The next scheduled bulk run still needs observation.
- **The database tier only got interim coverage on 2026-06-21** — ~12 Postgres + 1 Mongo on
  `ceph-rbd` now have logical dump CronJobs to SeaweedFS, mirrored by backup-stack into the
  Backrest `/mnt/hdd/data` source tree. This is a stopgap, not the final PITR design.
- **Time fuse defused 2026-06-21:** the offsite bucket no longer expires the repo, versioning is
  enabled, and only `restic/data/` + `restic-v2/data/` transition to Deep Archive.

## 1. Principles

- **Split by data type, not dogma.** Bulk files, databases, VM images, and cluster state each
  want a different mechanism.
- **Good duplication is the point.** Two *independent* restore paths (different mechanism or
  different failure domain) for anything we'd cry about losing. Don't engineer overlap to zero.
- **Alerting is mandatory.** The 5-month silent outage happened because the only freshness alert
  watched PBS. Every backup mechanism gets a freshness/success alert.
- **Code is source of truth.** Mechanisms live in tofu/ansible where possible; the offsite NAS is
  a deliberate exception (see §3).

## 2. Current state (grounded inventory)

**Storage tiers**
- **Ceph** — all-NVMe, hyperconverged on Proxmox (mons `192.168.2.202/204/205`). Backs RBD
  (`ceph-rbd`, default SC, **reclaim=Delete**), CephFS, and RGW. RGW is therefore *same failure
  domain* as the DB volumes.
- **`smith` ZFS** — 4×14TB **SATA** RAID-ish pool, exposed via NFS (`/mnt/hdd/data`, ~5.1Ti bulk)
  and hosting the PBS datastore (`/mnt/hdd/backups-vm`).
- **`talos-neo-local`** — 500Gi local NVMe (GPU models; re-derivable, no backup needed).

**What protects what today**

| Data | Lives on | Local backup | Offsite |
| --- | --- | --- | --- |
| Proxmox VM/LXC disks | Ceph vm-disks | ✅ PBS (daily 2AM, smith) | ✅ restic-v2 smoke verified; bulk scheduled daily |
| Bulk files (Immich 2Ti, Nextcloud 2Ti, media 1Ti) | smith NFS | ❌ sanoid *configured, not deployed* | ✅ restic-v2 smoke verified; bulk scheduled daily |
| CephFS shares | CephFS | ❌ | ✅ restic-v2 smoke verified; bulk scheduled daily |
| **~12 Postgres + 1 Mongo** | `ceph-rbd` | ✅ interim logical dumps → SeaweedFS | ✅ backup-stack mirrors dumps into `/mnt/hdd/data`, Backrest sweeps offsite |
| **~52 non-DB RBD PVCs** (Vaultwarden, matrix-synapse, memos, karakeep, app configs) | `ceph-rbd` | ❌ **none** | ❌ **none** |
| etcd / cluster state | Talos etcd | ✅ scheduled Talos snapshot → `/mnt/hdd/data/backups/talos-etcd` | ✅ included in the scheduled Backrest `/mnt/hdd/data` offsite snapshot |
| tofu state | S3+DynamoDB | ✅ (encrypted) | ✅ |
| SOPS secrets | git | ✅ | ✅ |
| **step-ca CA key** | identity VM | ✅ SOPS-encrypted in git (`secrets/step-ca-backup.yml`, `task backup:step-ca`) | ⚠️ offline copy (USB/paper next to the age key) still recommended, not yet done |
| restic repo password | backrest `config.json` only | ⚠️ **not in SOPS** | ❌ |

**Existing mechanisms**
- **PBS** — deployed/healthy. `backup-stack` LXC (id 1007) on smith. Daily 2AM, all guests,
  retention 3 daily / 2 weekly / 3 monthly.
- **restic/Backrest** — deployed and repaired 2026-06-21. Paths `/mnt/cephfs`, `/mnt/hdd/data`,
  `/mnt/hdd/backups-vm` → `s3://aether-home-offsite-backup/restic-v2`; auth = IAM Roles
  Anywhere + step-ca cert; the Backrest-managed restic binary is wrapped so each restic process
  mints fresh AWS credentials. Cert renewal is handled by systemd timer and only re-splits the
  renewed certificate bundle; it must not restart Backrest during active backups.
- **SeaweedFS** — restored 2026-06-21 as a NixOS LXC on Smith (`10.0.2.11`) with historical
  hostnames `seaweed.home.shdr.ch`, `s3.seaweed.home.shdr.ch`, and
  `master.seaweed.home.shdr.ch`. Direct and HTTPS S3 smoke tests passed. This is an interim
  on-prem target and is not yet the planned off-smith copy. DB dump CronJobs write to bucket
  `aether-db-dumps`; backup-stack syncs that bucket at 02:35 into
  `/mnt/hdd/data/backups/seaweed-db-dumps/aether-db-dumps`, which is covered by the existing
  Backrest `/mnt/hdd/data` plan. Backrest does **not** mount or snapshot Seaweed's live internal
  volume path.
- **Database protection** — interim dump jobs are live. CloudNativePG is installed with a
  `ceph-rbd` storage guardrail; Miniflux, Hoppscotch, Coder, Temporal, Affine, OpenWebUI,
  Nextcloud, Matrix, and Immich are migrated CNPG-backed app DBs. LiteLLM has an adopted/staged
  CNPG cluster, but the live app still writes to its in-pod Postgres sidecar.
- **Kubernetes control-plane protection** — `backup-stack` runs `aether-talos-etcd-snapshot.timer`
  daily at 02:20, using the Tofu-generated Talos client config. A manual proof snapshot on
  2026-06-27 wrote a 412MB etcd snapshot to `/mnt/hdd/data/backups/talos-etcd`; the scheduled
  2026-06-28 run wrote a 424MB snapshot, and the scheduled Backrest `/mnt/hdd/data` offsite
  snapshot includes both files. Prometheus scrapes `aether_talos_etcd_snapshot_*` metrics from
  the `aether-restic` exporter. Grafana alert rules cover failed and stale Talos etcd snapshots.
- **Freshness alerts** — now cover PBS, DB dump CronJobs, restic metrics/exporter, Backrest/restic
  plan freshness, and Talos etcd snapshot success/staleness. Additional coverage is still needed
  for broad CNPG Barman/WAL, k8up, sanoid, and PBS remote-sync.
- **Absent or partial:** sanoid (configured only), Ceph snapshots, Velero/k8up/volsync, and broad
  CNPG Barman/WAL archiving. Mnemo is the current exception with native CNPG object-store backup.

## 3. Target architecture — second failure domain on `neo`

The core fix is a **copy ② that is independent of both Ceph and `smith`**. Decision: host it on
**`neo`** using the 4× spare SAS drives — the cheapest viable option, accepted as a **secondary
tier** (not the sole copy of anything).

**Hardware (verified live on neo, 2026-06-21):**
- Board: **MSI MPG X870E Carbon WIFI** (Ryzen 9 9950X, 128GB).
- `PCI_E1` (PCIe 5.0 x16, CPU) = RTX Pro 6000 (vfio passthrough). `PCI_E2` (x4, CPU) = Intel 82599
  10GbE. **`PCI_E3` (PCIe 4.0 x4, chipset) = FREE** — ideal HBA slot: chipset-connected (does
  **not** touch CPU/GPU lanes), x4 ≈ 7.9 GB/s (overkill for 4 HDDs), 80mm slot spacing so the GPU
  doesn't block it.
- PSU is a dumb ATX unit (no telemetry) but sized for a ~600W GPU+CPU system → ample headroom for
  ~40W of drives; **zero SATA drives currently attached**, so power leads are almost certainly free.
- **[verify — physical, eyes-on]:** 4× 3.5″ bays in neo's case + ≥4 free SATA power leads. User
  believes it fits.

**Parts to buy (~$65):**
- LSI/Broadcom **9300-8i**, IT mode (native, no flashing) — ~$50.
- **SFF-8643 → 4× SFF-8482** SAS breakout cable (SAS connector, *not* the SATA breakout the HBA
  bundles ship with) — ~$15.
- Drives: 4× 14TB SAS already owned → ZFS **RAIDZ2 ≈ 28TB usable** (2-disk fault tolerance).

**neo's role caveat (agreed):** neo is the busiest/hottest/most-rebooted node. It is acceptable as
copy ② *only* because `smith` stays primary and AWS is the true DR. **Rule: never let neo hold the
only copy of anything.** A dedicated low-power box (used workstation + 9300-8i, ~$300, or a 45HomeLab
HL15) remains the "proper" long-term home if neo's coupling becomes painful.

**Target 3-2-1 per data class**

| Data | ① primary | ② local (off-Ceph, off-smith) | ③ offsite |
| --- | --- | --- | --- |
| VM/LXC disks | Ceph | PBS on smith **+** PBS remote-sync → neo | restic → AWS |
| Bulk files | smith ZFS | sanoid snapshots **+** `zfs send` → neo | restic → AWS |
| Databases | Ceph RBD (`ceph-rbd`, NVMe) | **CNPG** data PVCs stay on Ceph NVMe; WAL+base backups → SeaweedFS on neo/smith (PITR) | mirror Seaweed objects into Backrest source tree → AWS |
| Non-DB RBD PVCs | Ceph RBD | **k8up** restic → SeaweedFS on neo | sweep → AWS |
| etcd | Talos | scheduled `talosctl etcd snapshot` → backup-stack now; move to neo/copy ② later | `/mnt/hdd/data` Backrest plan → AWS |
| PKI / secrets | step-ca / git | — | step-ca CA key backed up to `secrets/step-ca-backup.yml` (done, `task backup:step-ca`); restic pw → SOPS |

## 4. Component decisions

1. **Keep restic, drop rustic.** Verified from source (rustic 0.11.3 → opendal-s3 0.57 →
   reqsign-aws-v4 3.0.1): rustic *silently ignores* `credential_process`. Fix restic's
   *fragility*, not the tool → **oneshot systemd timer** (mint creds per run → backup → exit;
   kills the daemon/cert-expiry/crash-loop failure modes).
2. **Centralize Postgres on CloudNativePG.** One operator = shared infra (aether tofu, alongside
   cert-manager). **One `Cluster` per app** (control-plane centralization, *not* one shared DB).
   The operator is installed in `cnpg-system` from the Helm chart and a Kyverno guardrail enforces
   `ceph-rbd` for CNPG `storage` and optional `walStorage`. Primary database PVCs stay on the Ceph
   RBD/NVMe-backed class (`ceph-rbd`); SeaweedFS is only the S3-compatible target for WAL
   archive/base backups and restore testing.
   Use the **Barman Cloud Plugin** (in-tree `barmanObjectStore` deprecated, removed in 1.30; needs
   operator ≥1.26 + cert-manager — already present). Migrate via **logical import**
   (`bootstrap.initdb.import`, microservice), one app at a time, quiescing writes for cutover.
   arm64 works (install via Helm, not OLM).
3. **DB backup target = on-prem, NOT AWS-direct.** WAL archiving is frequent small PUTs restored at
   LAN speed; Deep Archive is the wrong class and AWS-direct is slow + reintroduces the auth
   problem. **CNPG sidecar does not support `credential_process`** (no volume mount — verified
   against CRD + `env.go`), so it uses **static S3 keys** against an on-prem store.
4. **Revive SeaweedFS as the on-prem S3** — it already existed (git `a6da4f0`→`2a70620`, Dec 15–
   Jan 1) with tiered NVMe-hot/HDD-cold + S3 API + IAM. It is now restored on **Smith** as an
   interim NixOS LXC using the historical hostnames; final copy ② should still move to **neo** or
   a dedicated backup box so it survives a Smith loss. The current bucket is `aether-db-dumps`;
   backup-stack mirrors objects into `/mnt/hdd/data/backups/seaweed-db-dumps` for Backrest. Scope
   backup-only keys before CNPG/k8up production use.
5. **k8up for non-DB RBD PVCs** — restic of PVC data → SeaweedFS, with pre-backup hooks. (Alt
   considered: Ceph `rbd export-diff` → PBS; k8up chosen for file-level restore + k8s-native fit.)
6. **Deploy sanoid** (config already exists) for local ZFS snapshots of the bulk pool; add
   `zfs send/recv` to neo.
7. **etcd** — scheduled `talosctl etcd snapshot` now runs on backup-stack and writes to
   `/mnt/hdd/data/backups/talos-etcd` so the existing `/mnt/hdd/data` Backrest plan can sweep it
   offsite. Move the local copy to neo/copy ② when that tier exists.
8. **PKI/secrets gaps** — the **step-ca CA key** is now backed up (SOPS-encrypted in git via
   `task backup:step-ca`); an offline copy (USB/paper) next to the age key is still recommended
   but not yet done. **Seed the restic repo password into SOPS** (today it exists only in
   `config.json` — lose it and the repo is unrecoverable) remains outstanding.

## 5. Hardening fixes (cross-cutting)

- **Defuse the July-8 fuse:** stop the offsite repo self-deleting — drop the 181-day expiry (or
  keep a current generation in S3 Standard/IA), and re-enable/reconsider versioning.
- **Cert fragility:** the cert that expired was ~24h with a dead renewal daemon. Move to the
  oneshot model and/or a longer-lived, self-healing cert; **alert on the renewal daemon itself**,
  not just downstream TLS expiry.
- **Reclaim policy:** flip `ceph-rbd` PVCs off the default **Delete** (per-PVC Retain, at least for
  DBs + Vaultwarden + Matrix). `tofu prevent_destroy` does *not* stop a `kubectl delete`/namespace
  delete from destroying the RBD image.
- **Alerting coverage (the meta-fix):** freshness/success alerts for **every** mechanism — restic
  last-snapshot age per path, DB dump job success, k8up job status, etcd snapshot age, sanoid,
  PBS remote-sync — plus the cert-renew daemon health.

## 6. Phased rollout

- **P0 — done 2026-06-21:** verified live offsite state, defused the lifecycle fuse, rebuilt
  restic on `restic-v2`, reworked cert renewal, and confirmed a smoke snapshot lands in S3.
- **P1 — close the worst gaps:** stand up the **neo NAS** (HBA + drives + ZFS pool); interim DB
  protection is now live (per-DB `pg_dump`/`mongodump` CronJobs → SeaweedFS bucket →
  backup-stack mirror under `/mnt/hdd/data` → Backrest offsite) while CNPG is built; flip reclaim
  policy; step-ca CA key backup done (`task backup:step-ca`); seed restic password to SOPS; deploy
  sanoid; expand backup alerting.
- **P2 — databases done right:** CNPG operator + `ceph-rbd` storage guardrail are live; Miniflux,
  Hoppscotch, Coder, Temporal, Affine, OpenWebUI, Nextcloud, Matrix, and Immich are migrated.
  LiteLLM's CNPG cluster is adopted but not cut over. Next: Barman plugin/WAL archiving to
  SeaweedFS, then migrate remaining Postgres services one-by-one and retire the P1 pg_dump
  stopgap.
- **P3 — round out copy ②:** k8up for non-DB RBD PVCs; move etcd snapshot local copy to neo;
  PBS remote-sync + `zfs send` to neo.
- **P4 — prove it:** RTO/RPO targets per class; first **restore drill** (Vaultwarden + one Postgres
  + a Nextcloud file set); write the DR runbook (long-standing TODO).

## 7. Open items / to verify before/at build

- **[physical]** neo case: 4× 3.5″ bays + ≥4 SATA power leads (user believes it fits).
- **[live]** Complete the first successful PBS datastore Backrest run into `restic-v2`.
- **[decision]** Why was SeaweedFS deleted in Jan? (reliability matters for a backup role.)
- **[test]** CNPG Barman/WAL archive → SeaweedFS static-key auth, end to end, before migrating
  higher-value databases.
- **[decision]** neo as permanent copy ② vs. interim → dedicated box later.

## 8. Rejected alternatives (so we don't re-litigate)

- **rustic** — can't do `credential_process` (verified); buys nothing over restic.
- **CNPG → AWS S3 direct** — wrong storage class for WAL, slow restore, auth problem.
- **Ceph RGW for DB backups** — same failure domain as the DBs (all-NVMe Ceph).
- **MinIO** — community edition gutted (2025); SeaweedFS is the on-prem S3 instead.
- **Pi / mini-PC as the NAS** — SAS needs an HBA (no USB-SAS); Pi PCIe is x1/flaky; neither can
  house/power four 3.5″ spinners. mini-PCs have no bays.
- **1U rackmount** — works (used Dell R240/Supermicro SC813 + HBA) but loud; revisit only if neo
  doesn't pan out and a dedicated box is wanted.
- **Turnkey SAS NAS** — doesn't exist affordably; consumer NAS is SATA-only, real SAS appliances
  are $3k+ enterprise. Homelab SAS = "box + HBA + ZFS" by definition.
