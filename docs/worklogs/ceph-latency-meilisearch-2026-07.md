# Ceph latency incident — mnemo meilisearch index thrash (2026-07-07 → 2026-07-09)

Everything below is verified from Prometheus/PVE/k8s output on 2026-07-09 or from repo/helm state.

## Symptom

Cluster-wide ceph OSD latency bump starting 2026-07-07 ~06:00 UTC:

- avg read latency: 0.3–1 ms baseline → 6–11 ms sustained; writes 9 ms → 20–40 ms spikes
- all 6 OSDs degraded uniformly (not a disk)
- cluster read throughput: 1–2 MB/s baseline → ~200–240 MB/s sustained for 2+ days
- no recovery/backfill, no scrubbing — pure client IO

## Root cause

The 2026-07-07 06:39 UTC mnemo helm deploy attempt ran with `backfill.reset=true`
(release drift: the converge to `reset=false` — helm revision 6 — failed because Job
`spec.template` is immutable, and auto-rolled back). The backfill Job enqueued
`Mnemo.Jobs.IndexAllMessages(reset=true)`: a full wipe-and-reindex of ~87k messages,
fed to meilisearch 500 docs/batch by an Oban worker that waits for each meili task
before sending the next.

Meilisearch v1.12.8 (`mnemo-meilisearch-0`, PVC `data-mnemo-meilisearch-0`, mapped as
`/dev/rbd8` on talos-niobe) holds a 23 GiB LMDB index under a 4Gi memory limit. LMDB is
mmap'd; the cgroup page cache cannot hold the working set, so every indexing pass
re-reads the index from RBD: ~236 MB/s sustained, CPU ~0.25 cores (I/O bound). Batch
durations grew superlinearly with index size: 140 s (07-07 08:00) → 4 790 s (07-09),
i.e. slower than the batch arrival rate — the queue never drained.

Identification path, reusable for "who is hammering ceph": ceph-exporter OSD op rates →
`pve_network_receive_bytes` per guest (found talos-niobe; `router` and IDS RX were the
same flow transiting/mirrored) → otel `node_disk_read_bytes_total{host_name=…}` per
device → `talosctl read /sys/bus/rbd/devices/<n>/name` → PV/PVC by
`spec.csi.volumeAttributes.imageName`. Note: mgr-level `ceph_pool_*` metrics are not
scraped (only per-host ceph-exporter daemon counters), and pod-level network/fs metrics
don't see kernel RBD IO.

## Actions taken (2026-07-09)

1. RBD safety snapshot `kubernetes/csi-vol-aa18fa1f-4c82-4538-b286-47236f972be0@pre-v113`
   (snapid 391) — still present; delete once meili is stably back up.
2. Live patch (approved): STS image → `getmeili/meilisearch:v1.13.3` + one-shot
   `MEILI_EXPERIMENTAL_DUMPLESS_UPGRADE=true`. Dumpless migration succeeded in 17 s.
3. IaC converge (`mnemo.tf`): meili image pinned to v1.13.3; `backfill.enabled=false`
   (the Job is one-shot bootstrap tooling; re-rendering it on upgrade both trips the
   immutable-Job failure — exactly what broke helm revision 6 — and enqueues a duplicate
   full-reindex feeder). The inert completed Job was deleted so helm could converge.
   One-shot migration env removed post-upgrade; live == rendered chart.
4. **Measurement: v1.13.3 is not a fix at 4Gi.** It OOM-kills (exit 137) mid-batch
   instead of thrashing — its indexer budgets from the container limit and overshoots.
5. Stopgap (approved): `kubectl -n mnemo scale sts mnemo-meilisearch --replicas=0`.
   Cluster recovered immediately: reads 1.1 MB/s, read latency 1.08 ms, writes 8.7 ms.

## Resolution (2026-07-09, later the same day): Meilisearch removed entirely

Decision: search does not justify a memory-resident index. mnemo already had
Postgres FTS (`messages.search_vector` + GIN), pg_trgm, and pgvector RAG;
Meilisearch was an additive layer with a sync pipeline. mnemo commit
`2841df50` ("Replace Meilisearch with Postgres-native search") promotes the
SQL path to primary with full feature parity (ts_headline snippets, facets,
thread dedupe, date sort, sender-handle filter, bulk-mail exclusion, AND→OR
match strategy) and deletes the Meili client, index/backfill/audit jobs,
and chart StatefulSet. It also fixes a latent bug: the old SQL fallback
bound its filters as a jsonb *string* (postgrex re-encoded the
Jason-encoded payload), so fallback filters had never applied.

Instrumentation added for search optimization:
- OTel spans `mnemo.search_messages` / `mnemo.rag_context` (query, strategy,
  counts; SQL as child spans) — verified in Tempo.
- PromEx metrics `mnemo_search_request_duration_milliseconds`,
  `mnemo_search_request_results`, `mnemo_search_requests_total{zero_hits}`,
  `mnemo_rag_query_*` — verified in Prometheus. mnemo's `/metrics` had never
  been scraped; a `mnemo` job was added to the otel-collector deployment's
  prometheus receiver (`otel_collector.tf`).

Measured on live data (87k messages): warm queries ~20–260 ms, cold worst
case ~4.8 s (page-cache fill; buffer-managed — degrades slow, never OOM).

Decommissioned: meili STS/service (helm), PVC `data-mnemo-meilisearch-0`,
its Retain PV, the 3 nightly CSI VolumeSnapshots of that PVC, the
`pre-v113` rollback RBD snap, and the 100Gi RBD image
`kubernetes/csi-vol-aa18fa1f-…` (verified gone). SOPS `meilisearch.*`
entries removed (karakeep's meili is self-contained via `random_password`
and untouched).

## Open items

- ~~RAG reranker gateway down~~ — fixed in the follow-up below
  (`RERANKER_BASE_URL` pinned to ai-serving).
- Secondary finding: k8s RBD client traffic (10.0.3.x → ceph on 192.168.2.x)
  transits the `router` VM (~220 MB/s during the incident) and is mirrored
  into the IDS stack — every byte of k8s storage IO pays a routed-VM hop.


## Follow-up (2026-07-09 afternoon): bulk detection, reranker, and the is_bulk migration incident

mnemo commits `a0ac78ab` (broader bulk/newsletter detection: Gmail labels +
automated-sender patterns + unsubscribe-footer, via `api.message_is_bulk/3`),
`ba280380` (chart deploy strategy → Recreate), `7ef0add5` + `12825a03`
(is_bulk stored generated column; recency-bounded candidate pool +
`plan_cache_mode=force_custom_plan` on `api.search_messages`). 78% of the
314k-message corpus is bulk — default exclusion carries its weight.

RAG reranker fixed: mnemo's client default still pointed at
`llama-swap.infra.svc` (dead since the ai-serving namespace split);
`RERANKER_BASE_URL` now pinned in `mnemo.tf`. RAG fails fast when the
reranker is down — deliberate, per owner decision (no degraded mode).

### Incident: is_bulk column migration took down mnemo-cnpg

The `GENERATED … STORED` column = full rewrite of the 6.9GB messages table.
Chain of failures, each worth remembering:

1. **RollingUpdate + boot-time DDL deadlocks**: the new pod's ALTER queued an
   ACCESS EXCLUSIVE lock behind the old pod's live connections; the old pod
   wouldn't die until the new one was ready. Chart now deploys Recreate.
2. **The pending exclusive lock browned out everything**: all later readers
   queue behind a pending AccessExclusiveLock; even health checks stalled.
3. **Aborted rewrites + WAL burst filled the 10Gi PVC** → postgres down,
   CNPG phase "Not enough disk space". Storage now 30Gi in `mnemo.tf`; the
   fenced operator did not resize the PVC itself — patched to the declared
   size by hand (`FileSystemResizePending` resolves on pod restart).
4. **Zombie backends**: dead client pods left 6 server-side ALTERs — one
   held the lock 16 minutes (doomed to roll back on client EOF), five
   queued. `pg_terminate_backend` for all, then the migration was run
   manually via psql (exact SQL from the shipped migration file +
   `schema_migrations` insert): **ALTER took 14m10s solo** — helm's 900s
   deadline could never fit it. Boot-time migrations that rewrite big
   tables need a manual/controlled path.
5. Post-rewrite hygiene: `VACUUM ANALYZE messages` (hint bits + stats).

### Performance findings (instrumentation-driven)

- plpgsql cached generic plans cannot prune the `$n IS NULL OR col = $n`
  filter pattern → `plan_cache_mode=force_custom_plan` pinned on the
  function (in its definition, so CREATE OR REPLACE keeps it).
- Ranking every tsquery match detoasts a tsvector per row; stopword-class
  queries (30k matches) took 13s+. Candidate pool is now the newest
  `candidate_limit` matches (timestamp top-N, no detoast), ranked after.
- Steady state on live data: worst-case adversarial query 229ms warm,
  realistic queries 25–950ms, facets ~1.2s. Ceph at baseline throughout
  verification (r-lat 0.49ms).

## RAG overhaul (2026-07-09 evening) — five stacked causes, measured and fixed

"Why does RAG return substack footers?" decomposed into five independent
defects (mnemo commits f5be49f7, 9928f0d6, c12ddb72, 385f0f51, e39ff546):

1. **Index was 61% newsletter junk** — purged bulk chunks/embeddings/
   search_documents; `ChunkMessage` skips bulk at ingest; `api.rag_context`
   excludes bulk defensively (+ `plan_cache_mode` pin).
2. **Coverage was ~5%** — chunking was gated on the Gmail backfill and
   absent for Matrix. New `BackfillChunks` drain (newest-first, 30-min cron,
   self-healing) chunks everything non-bulk AND re-enqueues chunks whose
   embed jobs died (11.5k orphans from the 07-01 text-embedding-3-small
   era). Embeddings 24k → 47k+ and climbing at ~8/s (local qwen3 via
   llama-swap, zero external cost).
3. **Retrieval ordering starved semantic hits** — lexical-first sort with a
   strict-AND tsquery that never matches question phrasings. Now reciprocal
   rank fusion (k=60) of vector + content-word (len>=4) disjunctive FTS;
   rerank window floor 40 → 120.
4. **Query embeddings ignored qwen3's asymmetric-retrieval convention** —
   instruct-prefix on the query side only (no re-embedding needed) moved
   the target chunk from vector rank #1200 to #36.
5. **Reranker was DNS-dead** (fixed earlier: `RERANKER_BASE_URL` →
   ai-serving).

Verified end state for "who is my family doctor": top results are genuinely
relevant (family-physician emails, GP explainers) and the answer chunk
reaches the reranker. Remaining ceiling, isolated by direct A/B:
**bge-reranker-v2-m3 scores literal matches ("Family", -2.46) above
inferential ones ("fallen off Dr. Rehal's roster", -6.97)** while acing
clear-cut pairs (Paris test +7.9/-10.8) — a model-quality limit, not a
pipeline bug. Options: Qwen3-Reranker on llama-swap (llama.cpp support is
fragile: most community GGUFs lack cls.output.weight; needs --pooling rank
--embedding and a verified conversion) or lean on the MCP consumer
combining rag_context with keyword search (which answers the Rehal
question in one query).

Also hit during deploys: `proxmox_virtual_environment_download_file.talos_iso`
refresh now fails (upstream URL 404s) — pre-existing, breaks any targeted
apply that refreshes it; worked around with `-refresh=false`. Needs its own
fix.
