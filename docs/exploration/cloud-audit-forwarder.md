# Cloud provider telemetry forwarder ("vigil")

Status: implemented (2026-07). Collector binary lives in the `vigil` repo
(~/projects/vigil, image `registry.gitlab.home.shdr.ch/so/vigil`); this document
remains the design contract. Deployment: `cloud-audit` namespace via
`tofu/home/kubernetes`; alerting: `ansible/.../grafana/provisioning/alerting/cloud-audit.yml`.
Name `vigil` is a placeholder —
rename consistently if a better one exists (`argos` is taken).

## Problem

Cloud VM telemetry is covered (journal forwarder pulls journald from the AWS/GCP/OCI
boxes; CrowdSec metrics scraped from `10.1.0.10:6060`), but **no control-plane audit
event from any provider lands in the local stack**. CloudTrail, GCP Cloud Audit Logs,
OCI Audit, Tailscale device/ACL state, and Cloudflare audit logs are unqueried and
unalerted. This is the layer where compromise of the keyless trust chains
(Roles Anywhere, WIF, OCI UPST token-exchange) or of the crown-jewel objects
(offsite restic bucket, `openbao-auto-unseal` KMS key, WIF pool, OCI
IdentityPropagationTrust, public DNS) would appear first — and currently nowhere.

## Decisions already made (do not relitigate)

| Decision | Choice | Rejected alternative + why |
| --- | --- | --- |
| Ingestion | Direct API polling per provider | CloudTrail→S3 / GCP→Pub/Sub delivery plumbing: cloud-side infra for tens of events/day; Wazuh cloud modules: second evidence store outside Grafana, covers only 2/5 providers, manager hardening incomplete |
| Detection | ~15 estate-specific overlay rules (below) | Stock rulesets: tuned for orgs with human console noise; base rate of legit out-of-band mutation here ≈ 0 |
| Orchestration | Kestra scheduled flow using OSS `io.kestra.plugin.kubernetes.PodCreate` in a dedicated namespace | systemd on monitoring-stack: cluster-compromise argument reduces to detection latency, covered by feed-absent rules evaluated outside the cluster; Kestra is the converged automation plane (crowdsec-sync, estate-scan, Inquest) |
| Credential isolation | Nothing enters Kestra and nothing rests in etcd: vigil authenticates to Bao at runtime with its projected SA token and reads TS/CF tokens into memory; Kyverno pins the pod spec; Cilium `toFQDNs` pins egress; cloud trust conditions pin the ceiling | Kestra env secrets: OSS has no per-flow secret RBAC — any flow reads any `SECRET_*`; ESO-materialized k8s Secret: workable fallback, but leaves an at-rest copy in etcd |
| Auth | Keycloak roots all cloud access via a dedicated `cloud-audit` client/audience with parallel **read-only** trusts per provider. **Primary client auth: the pod's projected ServiceAccount token exchanged at Keycloak (RFC 8693)** — Keycloak sits inside the estate and can reach the Talos apiserver JWKS, so the KC+cloud path holds zero static secrets; the identity root is the k8s SA that Kyverno already pins. Fallback if Keycloak's external token exchange proves unavailable at our version/feature flags: confidential client secret via ESO/Bao | Reusing human trusts: all are sub-pinned to `keycloak_shdrch_sub`; direct IAM trust of the cluster issuer (IRSA-style): apiserver JWKS not publicly reachable for IAM — but Keycloak-side trust of the same issuer works, which is what the primary path uses |
| Sink | Signal-typed sinks, both shipped day 1: OTLP **logs** (audit events + run evidence) → Loki `domain=security`, and OTLP **metrics** (snapshot gauges + heartbeat) → Prometheus, through the same central collector. Each collector declares its signal type; adding a signal never touches auth, config, or cursoring | Wazuh indexer / new store: triage doctrine is one Grafana surface; logs-only: forces posture/reputation data (SES, Access Analyzer) into LogQL counts when they are gauges by nature |
| Language | Rust (see §Language) | Swift: single precedent in ~/projects, weaker Linux ecosystem for SigV4/OTLP; Go: fine, but the exporter scaffolding convention here is Rust |

## Architecture

```
Kestra flow (kestra ns, schedule every 5 min; collectors self-skip if not due)
  └─ PodCreate ──────────────► vigil pod (cloud-audit ns, run-to-completion)
                                 ├─ projected SA token (kubelet-rotated) → RFC 8693 exchange at Keycloak
                                 ├─ same SA token → Bao JWT login → read TS/CF tokens (in-memory only)
                                 ├─ /var/lib/vigil cursor PVC
                                 ├─ per collector: mint provider token (shared per provider) → collect
                                 │    AWS  : KC JWT → sts:AssumeRoleWithWebIdentity → cloudtrail:LookupEvents,
                                 │           accessanalyzer:ListFindings*, ses:GetSendStatistics
                                 │    GCP  : KC JWT → STS exchange → SA impersonation → Logging API
                                 │           (admin-activity entries)
                                 │    OCI  : KC JWT → UPST token-exchange → Audit API ListEvents
                                 │    TS   : API token → devices/keys/ACL endpoints (state diff, not a log)
                                 │    CF   : API token → account audit logs endpoint
                                 ├─ normalize → OTLP logs (events) + OTLP metrics (gauges)
                                 │      → https://otel-metrics.home.shdr.ch (or in-cluster collector)
                                 └─ per-collector heartbeat: metric + run-summary log line (see Alerting)
```

Run-to-completion, not a daemon: fresh short-lived cloud credentials per run, discarded
at exit. No renewal logic anywhere (this deletes the UPST-1h problem by construction).

### Collector model

The unit of work is a **collector**, not a provider: `aws.cloudtrail`,
`aws.access_analyzer`, `aws.ses_stats`, `gcp.audit`, `oci.audit`, `tailscale.state`,
`cloudflare.audit`. Provider auth (token minting) is a shared session layer; collectors
are gigahub-exporter-style independent units on top of it, each declaring:

- **kind**: `log-tail` (cursor over an event API), `state-diff` (snapshot + synthetic
  change events — Tailscale), or `snapshot` (point-in-time reads, no cursor).
- **signal type**: `log-tail` and `state-diff` collectors emit OTLP **logs**
  (discrete events are evidence — they belong in Loki next to Zeek/Keycloak);
  `snapshot` collectors emit OTLP **metrics** (`aws.ses_stats` →
  `vigil_aws_ses_bounce_rate` etc.; `aws.access_analyzer` →
  `vigil_aws_access_analyzer_findings{analyzer,status}` — posture and reputation are
  gauges by nature, and their rules are PromQL thresholds/deltas, not LogQL counts).
  Metric naming: `vigil_<provider>_*`, per the fleet exporter convention
  (`gigahub_*`, `vyos_*`).

Config enables **collectors**, not providers. New collectors must not require changes
to existing ones.

### Normalized event schema

One schema across all five providers so rules and dashboards are uniform:

- Loki labels: `service_name="vigil"`, `provider` (aws|gcp|oci|tailscale|cloudflare),
  `collector`, `domain="security"`.
- Structured metadata / body fields: `event_time`, `event_source`, `event_name`,
  `principal`, `source_ip`, `resource`, `raw` (full provider JSON, untruncated).
- Tailscale is a **state differ**, not a log reader: persist previous device/key/ACL
  snapshot in the cursor dir; emit synthetic events (`device.added`, `device.tagged`,
  `route.approved`, `acl.changed` with the diff) on change.

### Cursor semantics

- One cursor per **collector** under the PVC (`log-tail`), or a prior-state snapshot
  (`state-diff`); `snapshot` collectors keep nothing. Advance only after OTLP export
  acknowledges.
- Fresh deploy / lost PVC: seed to `now` (journal-forwarder convention — no backfill
  floods). Namespace gets `backup=none` + `aether.shdr.ch/data=rebuildable`.
- Half-open windows `[cursor, now)`; provider event-delivery lag (CloudTrail ≤ ~15 min)
  handled by overlapping lookback + dedupe on provider event ID, not by trusting
  wall-clock ordering.

## New sibling repo: `~/projects/vigil`

Model scaffolding on `gigahub-exporter` / `otel-journal-gatewayd-forwarder` (Rust
exporter convention) and CI on `aether-k8s-node-remediator` (on-cluster image
convention):

- `flake.nix` dev shell (rustc, cargo, clippy, rustfmt, cargo-deny), `rust-toolchain.toml`,
  `deny.toml`, `rustfmt.toml`, `CHANGELOG.md`, `config.example.toml`, MIT/Apache-2.0.
- **`vigil check --config …` preflight subcommand** (gigahub-exporter pattern), read-only:
  `config` → `keycloak-token` (SA-token exchange, or client-credentials on the fallback
  path) → `bao-read` (login + one kv read, value discarded) → per-provider `exchange-<p>`
  (mint provider credential, one cheap read call, discard) → `otlp-reachable`. One
  `ok:`/`FAIL:` line per check, exit 0 iff no FAIL. This is also the P0 verification tool.
- `run` subcommand: the pod entrypoint described above. Per-**collector** enable flags in config.
- `docs/schema.md`: the **stable contract** for everything vigil emits — normalized
  field names and semantics, the `provider`/`collector` label values, the run-summary
  heartbeat contract, and every `vigil_<provider>_*` metric (name, type, labels,
  absence semantics).
  Aether's alert rules and dashboards are written against this
  document (gigahub-exporter `docs/metrics.md` pattern); changing it is a breaking
  change and says so.
- Tests: hand-authored JSON fixtures per provider response shape under `tests/fixtures/`
  (LookupEvents page, Logging entries list, OCI audit page, TS device list pair for the
  differ, CF audit page); parser + normalizer + cursor-window unit tests. No live-API
  tests in CI.
- `.gitlab-ci.yml`: nix `validate` (clippy, fmt, cargo-deny) → `test` → buildah
  multi-arch (amd64+arm64) image → `$CI_REGISTRY_IMAGE`, tag = short SHA, `stable` on
  tags — copy the node-remediator jobs. **No CI deploy job**: aether tofu consumes the
  image by digest (Kyverno enforces this).
- Crates (suggested, executor's call): `reqwest`+`rustls`, `serde`, `tokio`,
  `opentelemetry-otlp` (logs), `aws-sigv4`/`aws-credential-types` or minimal
  `aws-sdk-cloudtrail`+`aws-sdk-sts` (SigV4 for LookupEvents after the STS exchange).
  GCP/OCI/TS/CF are plain OAuth/token HTTP — no SDK needed.

## Aether-side changes (this repo)

### 1. Keycloak (tofu/home, alongside existing realm IaC)

- Client `cloud-audit` with a dedicated audience mapper emitting `aud=cloud-audit`
  (these tokens can never satisfy `aud=toolbox` role conditions, and vice versa).
- **Primary auth path — projected SA token exchange (zero static secret):**
  - The vigil pod mounts a `serviceAccountToken` projected volume, custom audience
    (e.g. `keycloak:cloud-audit`), short TTL; kubelet rotates it.
  - Keycloak realm gets an OIDC identity-provider entry trusting the Talos cluster's
    service-account issuer, JWKS URL pointed at the apiserver's `/openid/v1/jwks`
    (explicit JWKS config — public reachability is not required, only
    Keycloak-VM→apiserver reachability). Restrict the trust to `sub ==
    system:serviceaccount:cloud-audit:vigil` and the custom audience.
  - The pod exchanges that SA token at the Keycloak token endpoint (RFC 8693
    `token-exchange`) for a realm token carrying `aud=cloud-audit`.
  - Result: the entire Keycloak+AWS/GCP/OCI chain is rooted in the kubelet-rotated
    SA token — the same SA the Kyverno pod-spec pin already enforces. Nothing static.
- **Fallback path** (only if the executor verifies external-subject token exchange is
  not usable on our Keycloak version/feature flags): confidential client with
  client-credentials grant, secret delivered via ESO/Bao as originally designed.
  Record which path shipped in this doc.
- Export the **`sub` the providers must trust** as a tofu output — the SA-token-exchange
  subject on the primary path, or the client's service-account user sub on the fallback.
  Wire it as a resource reference, not a hardcoded string, so it is a single apply.

### 2. AWS (`tofu/aws/`)

- `aws_iam_openid_connect_provider.keycloak.client_id_list`: append `cloud-audit`.
- New role `aether-cloud-audit`, trust = existing IdP ARN + condition
  `sub == <cloud-audit SA sub> && aud == "cloud-audit"`, `max_session_duration` 1h.
- Inline policy, exactly: `cloudtrail:LookupEvents`;
  `access-analyzer:ListFindings`, `access-analyzer:ListFindingsV2`, `access-analyzer:ListAnalyzers`;
  `ses:GetSendStatistics`, `ses:GetAccount`. Nothing else; never a managed admin policy.

### 3. GCP (`tofu/google/`)

- New SA `cloud-audit@…` with `roles/logging.viewer` on the project (admin-activity
  audit logs are readable with this; no sink/Pub/Sub is created).
- WIF: admit the new subject — either an attribute condition extension on the existing
  provider or a sibling provider mapping `aud=cloud-audit`; bind
  `roles/iam.workloadIdentityUser` for that principal to the new SA only. Do not widen
  the `aether-tofu` binding.

### 4. OCI (`tofu/oci/federation.tf`)

- Dedicated read-only Identity Domain user + group; tenancy policy
  `allow group cloud-audit-readers to read audit-events in tenancy`.
- Second `IdentityPropagationTrust` (clone the existing one's finicky pinned fields —
  `subject_mapping_attribute = userName`, `oauth_clients` list, impersonation off)
  mapping the `cloud-audit` client's sub to that user. The existing trust's comments
  document which fields IDCS 400s/500s on; expect one live-iterate cycle here like the
  original federation work. Reuse the existing confidential token-exchange app or mint
  a sibling — executor verifies whether one app can serve two trusts before duplicating.

### 5. Tailscale + Cloudflare tokens

- Tailscale: `tailscale_oauth_client` with read scopes (`devices:core:read`,
  `policy_file:read`, `auth_keys:read` — verify exact scope names against provider docs).
- Cloudflare: `cloudflare_api_token` scoped to account **Audit Logs Read** (+ Zone Read
  if the audit endpoint requires zone enumeration).
- Both land in SOPS → mirrored to Bao `kv/aether/cloud-audit` (fleet.enroll_secret
  precedent for the SOPS→Bao mirror).

### Credential inventory — what is static and why

"Keyless" holds for the Keycloak and cloud-provider legs (primary path); two static
secrets remain, each with a stated reason and ceiling. Do not add more without
amending this table.

| Credential | Static? | Ceiling | Why irreducible / mitigation |
| --- | --- | --- | --- |
| AWS / GCP / OCI credentials | **No** — minted per run, ≤1h, never at rest | read-only audit APIs | Keycloak federation (existing IdP/WIF/UPST trusts) |
| Keycloak leg | **No (primary path)** — kubelet-rotated projected SA token (short TTL) exchanged at Keycloak per run | mint `aud=cloud-audit` tokens → the read-only roles above, nothing else | requires Keycloak external-subject token exchange (verify; see Known risks). Fallback: static client secret in Bao, rotatable in one tofu apply |
| Tailscale OAuth client secret | Yes | mints short-lived API tokens with read-only scopes | Tailscale has no workload federation; the OAuth client is the least-static option it offers |
| Cloudflare API token | Yes | Audit Logs Read (+ Zone Read if required) | Cloudflare API tokens have no federation, period. Set a TTL and rotate via the `cloudflare_api_token` resource |

The two static secrets rest only in SOPS/Bao and are read into pod memory at runtime
via Bao JWT auth (no etcd copy, Bao-audited per read); the Kyverno pod-spec pin and the
`toFQDNs` CNP bound what can read them and where they can travel.


### 6. Namespace + isolation (`tofu/home/kubernetes/`)

- `module.namespace["cloud-audit"]`: tier `agent` (the egress-controlled tier is built
  for exactly this), `owner=platform`, `backup=none`, `exposure=none`,
  `criticality=normal`, annotation `aether.shdr.ch/data=rebuildable` (cursor PVC),
  `source` = this file.
- **Secrets are fetched from Bao at runtime, not materialized as k8s Secrets.** Bao
  gets a JWT auth role trusting the cluster SA issuer (the same issuer trust P0
  verifies for the Keycloak leg), bound to `system:serviceaccount:cloud-audit:vigil`
  + the projected-token audience, with a read-only policy on
  `kv/data/aether/cloud-audit`. At pod start vigil logs in with its projected SA token
  and reads the TS/CF tokens into memory; nothing rests in etcd, every read lands in
  the Bao audit log, and revocation is a Bao policy edit. No `ExternalSecret`, no
  per-ns `SecretStore`, no env-mounted secret for this namespace. (If the JWT-auth
  route hits a blocker, the fallback is the per-namespace ESO SecretStore pattern —
  record which shipped.)
- **Kyverno ValidatingPolicy scoped to the namespace** (CEL v1 types, per repo policy):
  pods MUST use the digest-pinned vigil image (digest from a tofu local, updated on
  release), the namespace SA, **no secret mounts at all** (runtime Bao fetch), no
  command/args override, no other workload kinds. This is what makes Kestra's
  pod-create power inert — the only pod that can exist here is the legitimate one.
- Cilium CNP (`toFQDNs`, agent-tier pattern): egress allowlist only —
  `auth.shdr.ch`; `bao.home.shdr.ch`; `sts.amazonaws.com` + regional `cloudtrail`/`accessanalyzer`/`email`(SES)
  endpoints; `sts.googleapis.com`, `iamcredentials.googleapis.com`, `logging.googleapis.com`;
  the OCI identity-domain URL + `audit.ca-toronto-1.oraclecloud.com`;
  `api.tailscale.com`; `api.cloudflare.com`; the OTLP ingest host; kube-dns. The CNP
  doubles as the documented reach of the poller.
- PVC (ceph-rbd, 1Gi) for cursors.

### 7. Kestra (`kestra/flows/` + `tofu/home/kestra-flows/`, per kestra.tf comment convention)

- Namespaced `Role`/`RoleBinding`: Kestra's SA may `create/get/watch/delete` pods and
  read pod logs in `cloud-audit` **only**. No ClusterRole.
- Flow `cloud-audit-poll`: `Schedule` trigger every 5 min → `PodCreate` (spec references the
  digest-pinned image, `restartPolicy: Never`, resource requests per LimitRange) →
  wait for completion → surface pod logs; `resume: true`/retry semantics per existing
  flow conventions. Kestra holds no cloud or Keycloak material — it only schedules and
  observes.
- **Cadence is per-collector, not per-flow.** The 5-min schedule is the base tick;
  each collector declares an `interval` in config and self-skips when not due
  (last-run timestamp in the cursor dir). Defaults: **5 min** for the mutation feeds
  (`aws.cloudtrail`, `gcp.audit`, `oci.audit`, `cloudflare.audit`, `tailscale.state`).
  For the near-real-time sources (GCP, Tailscale, Cloudflare) the interval IS the
  detection latency (~6 min worst case to rule eval); for CloudTrail/OCI the
  providers' own ~5–15 min delivery lag dominates (~20 min worst case). Cost is zero
  at this volume — every API is free and `LookupEvents`' 2 TPS is a rate, not a
  quota; below 5 min you poll inside the providers' lag window for no gain. **Daily**
  for posture snapshots (`aws.access_analyzer`, `aws.ses_stats`) where freshness buys
  nothing. A skipped-because-not-due collector emits no heartbeat line; the
  feed-absent thresholds below are sized per cadence class.
- Flow failure alerting comes from the Loki heartbeat rules below, not from
  Kestra-internal alerting.

### 8. Grafana (ansible/playbooks/monitoring_stack/grafana/provisioning/alerting/)

**Ownership: all rules, dashboards, and routing live aether-side — never in the vigil
repo.** Grafana is file-provisioned by the monitoring_stack playbook; the API is
IaC-read-only by doctrine, and rule deletion requires `deleteRules` tombstones in the
same provisioning file, so rule lifecycle must be single-owner. This matches the argos
and Inquest split: the sibling repo owns code + emitted-data contract (`docs/schema.md`),
aether owns the Grafana surface. Rule changes must not require a vigil release.

All new rules ship `severity: warning` first under **soak-then-promote** (14 days clean,
then a single reviewed commit flips the page-class ones to `critical`). Suppressions
in-rule as code. Target post-soak state:

| Rule (uid prefix `cloud-audit-`) | Provider | Condition (normalized fields) | Post-soak severity / channel |
| --- | --- | --- | --- |
| aws-root-or-console-login | aws | `event_name` in ConsoleLogin (root or no-MFA) | critical (page) |
| aws-iam-mutation | aws | IAM Create*/Put*/Attach*/Update* on users, roles, policies, OIDC IdP | critical (page) |
| aws-kms-unseal-key-tamper | aws | key-policy/schedule-deletion/disable on `openbao-auto-unseal` key; Decrypt denied-or-unexpected-principal | critical (page) |
| aws-backup-bucket-tamper | aws | PutBucketVersioning/Policy/Lifecycle/PublicAccessBlock on offsite restic bucket | critical (page) |
| aws-rolesanywhere-anomaly | aws | CreateSession with CN ∉ {bao.home.shdr.ch, backup-stack.home.shdr.ch}; trust-anchor/profile mutation | page for mutation, digest for anomaly |
| aws-access-analyzer-finding | aws | PromQL: `increase(vigil_aws_access_analyzer_findings{status="active"}...)` > 0 | warning (digest) |
| aws-ses-reputation | aws | PromQL: `vigil_aws_ses_bounce_rate` / complaint rate over threshold | warning (digest) |
| gcp-wif-or-iam-mutation | gcp | admin-activity on WIF pool/provider, IAM bindings, SA keys, API keys | critical (page) |
| oci-trust-or-iam-mutation | oci | IdentityPropagationTrust / confidential-app / policy / group changes | critical (page) |
| oci-instance-or-network-change | oci | instance lifecycle, security-list changes | warning (digest) |
| tailscale-device-or-route | tailscale | synthetic `device.added` / `route.approved` / tag change | page if admin-gateway tag or route; else digest |
| tailscale-acl-drift | tailscale | live ACL ≠ declared (`acl.changed` without matching apply) | warning (digest) |
| cloudflare-dns-or-zone-change | cloudflare | audit entry touching DNS records, SSL mode, API tokens | warning (digest); promote to page for records `@`, `*`, MX |
| any-mutation-outside-apply-window | all | mutation event with no tofu apply in ±30 min (correlate with CI/apply marker — coordinate with the continuous-deployment Phase 0 drift work; ship disabled if the marker signal doesn't exist yet) | critical (page) |
| **vigil-run-failed** | meta | `vigil_collector_run_ok == 0` for any collector (Prometheus) | warning |
| **vigil-feed-absent** | meta | `time() - max_over_time(vigil_collector_last_success_timestamp_seconds[2h]) > 1800` (5-min collectors) / `> 93600` (daily) — heartbeat, not event count; zero events is normal | warning |

The heartbeat is a metric pair pushed per collector per run
(`vigil_collector_last_success_timestamp_seconds`, `vigil_collector_run_ok`, plus
`vigil_collector_run_events`), with a structured run-summary **log line** (`provider`,
`collector`, `kind`, `events`, `ok`, `cursor`) kept as forensic evidence in Loki.
Alerting keys on the metrics: `time() - last_success` is the natural staleness
expression — note the `max_over_time(...[2h])` wrapper, required because push-gauges
from a run-to-completion pod go Prometheus-stale ~5 min after the last write. This is
the journal-forwarder poll-stale contract (`ojgf_*`) translated to pushed OTLP. These
two meta-rules are what make the "Kestra could be dead/compromised" concern moot —
they evaluate on monitoring-stack, outside the cluster.

- Security Triage dashboard: add a `vigil` signal-stats panel + recent-events table per
  provider, matching the existing per-head layout.

## Phases

Each phase gates the next; acceptance is observable, not "code merged".

**P0 — identities and trusts (aether tofu only).**
Keycloak client + issuer trust, AWS role, GCP SA/WIF, OCI trust/user, TS/CF tokens,
Bao kv. **First deliverable: verify the primary auth path** — Keycloak external-subject
token exchange of a cluster SA token (version/feature flags, apiserver JWKS reachability
from the Keycloak VM, Talos issuer URL). If it fails, record why here and ship the
fallback client secret.
Acceptance: from a dev shell, a throwaway script proves for each of AWS/GCP/OCI:
(a) a `aud=cloud-audit` Keycloak token (via the chosen path) → provider credential
succeeds; (b) the read call succeeds; (c) **negative test: the same token cannot assume
`aether-admin` / impersonate `aether-tofu` / act as the human OCI user**, and an SA
token from any *other* namespace/SA is rejected at the Keycloak exchange.
TS/CF tokens verified with one read call.

**P1 — vigil repo, AWS provider end-to-end (both signal types).**
Scaffold + `check` + `run` with the AWS collectors only — `aws.cloudtrail` (logs) plus
`aws.ses_stats`/`aws.access_analyzer` (metrics), so both sinks are exercised from day
one; fixtures tests green; from a local run with P0 credentials, CloudTrail events
visible in Loki and `vigil_aws_*` gauges + heartbeat metrics visible in Prometheus.
Acceptance: `vigil check` exit 0; a synthetic IAM event (e.g. tag a role) appears in
Grafana Explore under `{service_name="vigil", provider="aws"}` within one poll
interval; `vigil_collector_last_success_timestamp_seconds` queryable for all three
collectors.

**P2 — on-cluster.**
Namespace, ESO/Bao, Kyverno pin, CNP, PVC, Kestra Role + flow, image digest pinned in
tofu. Acceptance: scheduled run completes in-cluster; heartbeat metrics + summary lines present for AWS;
Kyverno rejects a hand-crafted rogue pod in the namespace (test it); CNP verified by a
blocked canary egress; the tokens exist nowhere in etcd (`kubectl get secrets -n
cloud-audit` shows none beyond system defaults) and not in Kestra env; a Bao audit-log
entry exists per run.

**P3 — remaining providers.** GCP, OCI, Tailscale differ, Cloudflare, each with fixtures
+ a live synthetic-event check (add/remove a tag, touch a DNS TXT, etc.).

**P4 — alerting + cleanup.** All rules provisioned warning-first; Security Triage
panels; docs sweep (`docs/monitoring.md` alert tables + security-triage buckets,
`docs/aws.md`, `docs/google-cloud.md`, `docs/tailscale.md`, `docs/cloudflare.md` each
gain their audit-collection paragraph); `docs/todos.md` entry for the soak-promotion
commit ~14 days out.

## Language: Rust, not Swift

- Three sibling exporters (`vyos-exporter`, `qss-exporter`, `gigahub-exporter`) plus
  `otel-journal-gatewayd-forwarder` define a mature in-house Rust scaffold: flake dev
  shell, `check` preflight, fixtures-first tests, cargo-deny, buildah multi-arch CI.
  vigil is a fourth instance of that shape, not a new species.
- Needed libraries all first-class in Rust on Linux: rustls, SigV4 (`aws-sigv4`),
  OTLP logs (`opentelemetry-otlp`), OAuth = plain reqwest. Swift-on-Linux has one
  precedent here (`espn-mcp`) and no SigV4/OTLP story without hand-rolling; it would be
  the second convention beside an established one.
- Static musl builds → scratch-ish multi-arch images, small attack surface for a pod
  that holds credentials — consistent with the Kyverno digest-pin story.

## Non-goals

- No Wazuh cloud modules, no CloudTrail→S3 trail, no GCP sinks/Pub/Sub, no Logpush.
- No remediation or live mutation of any provider — read-only by trust-policy ceiling.
- No Kestra EE features (task runners, namespace secrets, RBAC).
- No CloudWatch/Lightsail host-metric ingestion (node-exporter on the boxes already
  covers host telemetry); no budget/billing collectors until someone actually wants
  the dashboard.
- No backfill of historical audit events beyond first-run seeding.

## Known risks / open items for the executor

- **OCI IDCS is finicky**: the second trust will likely need a live-iterate cycle;
  the pinned-field comments in `federation.tf` are the map. Budget for it.
- **Primary-path verification (P0 gate):** Keycloak external-subject token exchange is
  version/feature-flag sensitive; the apiserver JWKS endpoint may need
  `system:service-account-issuer-discovery` bound for unauthenticated access (or an
  explicit JWKS fetch credential), and the trusted issuer string must exactly match the
  Talos `service-account-issuer`. Verify all three before building on it; the static
  client secret is the designed fallback, not a failure.
- Trusted-`sub` ordering in tofu (§1) — keep it one apply via resource references.
- CloudTrail `LookupEvents`: 2 TPS, 90-day history, ~15-min delivery lag — fine at this
  volume; keep per-run paging under the rate limit and rely on cursor overlap + event-ID
  dedupe.
- Tailscale OAuth scope names and the CF audit endpoint shape should be verified against
  current API docs at implementation time, not this document.
- The apply-window correlation rule depends on a tofu-apply marker signal that may not
  exist until the continuous-deployment Phase 0 work; ship it disabled rather than
  inventing a marker here.
- Keycloak and Bao become availability dependencies of audit collection (token exchange
  and runtime secret fetch respectively). Accepted: both are already page-class outages,
  and feed-absent rules catch the silence either way.
- Bao JWT auth trusting the cluster issuer shares P0's issuer/JWKS verification with the
  Keycloak leg — verify once, wire twice.
