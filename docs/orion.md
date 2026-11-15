# Orion

Orion is the personal AI dashboard and start page at `home.shdr.ch`, built
from `so/orion`. Its Helm release and Aether-owned objects and agents are in
[`orion.tf`](../tofu/home/kubernetes/orion.tf); the release pin is in
[`orion_release.tf`](../tofu/home/kubernetes/orion_release.tf).

## Database Storage

`orion-cnpg` uses a 50 GiB `ceph-rbd` volume, declared in
`kubectl_manifest.orion_cnpg_cluster` in `orion.tf`. Database data and WAL
share this volume.

On 2026-11-08, the volume was expanded from 5 GiB after CNPG refused to
start PostgreSQL with `no free disk space for WALs`. Barman WAL uploads were
failing with S3 `PutObject InternalError`. The Cluster storage change was
applied through OpenTofu; its PVC remained at 5 GiB, so an operator-approved
PVC resize completed the expansion to the declared 50 GiB. The mounted
filesystem then reported 45 GiB available, CNPG became Ready, and a SQL
query against `orion` succeeded. Expansion restores headroom but does not
repair the WAL archive destination.

## Release And Ownership Handover

Orion's chart owns only Deployment/Service `orion` in namespace `orion` and
Agents `orion`, `coordinator`, and the eight `orion-feed-*` topic Agents in
`org-personal`. Aether retains `dev`, `notes-keeper`, namespaces, Secrets,
static MCP credentials, PVCs, CNPG/backups, egress, HTTPRoute, QA browser,
Keycloak, Cedar and CRDs. Dev retains the shared gateway authentication,
ask policy and ClickStack tool list in Aether. Do not use old direct-Agent
patch/apply recipes.
The production chart must not override `agents` in `orion_chart_values.json`;
Agent definitions ship with Orion. Capture only non-secret workload settings,
including allocated Service addresses and admission defaults.

All commands here run from the Aether root inside `nix develop --command`.
Check credentials with `nix develop --command task login:status`, and verify
`nix develop --command kubectl config current-context` prints
`admin@aether-k8s` before any cluster or Helm access. Never force-unlock state.
The commands describe an operator-reviewed procedure, not an automatic deploy.

### First Adoption Only

Do not apply the handover patch until the disposable adoption proof passed,
service authorization is deployed, and rendered/live parity covers all twelve
objects with the actual intended image SHA. Replace `<RECAPTURE_SHA>` with
the full 40-character SHA whose same-SHA main image and chart were published
and whose image was deployed through the legacy Deployment before adoption.
The current deployed `d13849f22cb7e16d9abff4a5a33ea5255e468d0e` does not
contain the refreshed chart. Gate/push a new release, deploy its image first,
recapture workload values and require `check.sh --live` at that new image tag.
Never overwrite an immutable old chart tag or adopt with a different image
merely to make the chart pull succeed. Never apply with the placeholder pin.

Before removing the legacy resource definitions, stage ownership in those
existing definitions and apply a separately reviewed annotation-only plan:

- Merge `app.kubernetes.io/managed-by = Helm` into resource metadata labels.
- Merge `meta.helm.sh/release-name = orion` and
  `meta.helm.sh/release-namespace = orion` into resource metadata annotations.
- Apply this to the Deployment, Service, both core Agents and every feed
  for_each instance. Never add it to pod metadata or Agent specs; do not adopt
  the default ServiceAccount. The Agent release namespace annotation is
  `orion`, even though those Agents live in `org-personal`.

While all five legacy resource definitions still exist (before applying
the handover patch), save and review the ownership plan:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu plan -input=false -lock-timeout=120s -target=module.home.module.kubernetes.kubernetes_deployment_v1.orion -target=module.home.module.kubernetes.kubernetes_service_v1.orion -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_coordinator_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_feed_agent -out=/tmp/orion-ownership.plan'
nix develop --command bash -c 'tofu -chdir=tofu show -json /tmp/orion-ownership.plan | jq -r ".resource_changes[] | select(.change.actions != [\"no-op\"]) | [.address, (.change.actions|join(\",\"))] | @tsv"'
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu apply -input=false /tmp/orion-ownership.plan'
```

The apply command is conditional on review and explicit approval, never run
as an unattended three-command chain.

Review its JSON: only twelve metadata updates are allowed; no spec changes, pod rollout,
Agent revision changes, creates or deletes. Capture uid before this stage;
then capture uid/resourceVersion/generation/spec, pod identity/imageID/restart
count, Agent revision hashes, and active Orion/coordinator session identities
after annotation settlement. Preserve a secure state backup outside git.
Only then install the handover patch (the removed blocks are migration
history, not destroy instructions), and save the handover plan:

```bash
nix develop --command bash -c 'umask 077; mkdir -p /tmp/orion-adoption; export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu plan -input=false -lock-timeout=120s -target=module.home.module.kubernetes.kubernetes_deployment_v1.orion -target=module.home.module.kubernetes.kubernetes_service_v1.orion -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_coordinator_agent -target=module.home.module.kubernetes.kubectl_manifest.daimyo_orion_feed_agent -target=module.home.module.kubernetes.helm_release.orion -out=/tmp/orion-adoption/handover.plan'
nix develop --command bash -c 'umask 077; tofu -chdir=tofu show -json /tmp/orion-adoption/handover.plan > /tmp/orion-adoption/handover.json; jq -r '\''.resource_changes[] | select(.change.actions != ["no-op"]) | [.address, (.change.actions|join(","))] | @tsv'\'' /tmp/orion-adoption/handover.json'
```

Require exactly twelve `forget` actions (Deployment, Service, two core Agents,
eight feed instances) and one `helm_release.orion` create. All other
resources must be no-op: no delete, replacement, or unrelated update. Target
the whole feed resource, not just a selected topic. Recheck actual-release
render/live parity immediately before the explicitly approved apply:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu apply -input=false /tmp/orion-adoption/handover.plan'
```

Compare all before/after identities/specs and revision hashes; explain any
status-only resourceVersion change rather than accepting a spec change.
Require unchanged Service uid/addresses and Deployment pod uid, ReplicaSet
hash, imageID and restart count, and replies in the same pre-existing Orion
and coordinator sessions. Smoke Home/Notes, service identity/policy denials,
and a natural nested feed schedule/ingestion. No handover rollout or Agent
revision is expected. The first release is deliberately `atomic=false` and
`cleanup_on_fail=false`: on failure, inspect and repair retained objects and
state; do not uninstall, force-update, replace, use take-ownership, run state
rm, or recreate old Tofu owners. After successful adoption, set `atomic=true`
in a separately reviewed release-metadata-only apply; keep
`cleanup_on_fail=false`. Keep removed blocks until every state consumer has
crossed the migration.

### Ordinary Releases After Adoption

1. In Orion, run the existing Coder gate at the reviewed commit (no local Mac
   Node/npm), then fast-forward push that commit to `main` and `dev/revamp`.
   A non-fast-forward refusal is a stop, not permission to force-push.
2. Require successful image-build, chart-check and chart-publish for the same
   full lowercase 40-character SHA. Authenticate and pull both immutable
   artifacts: image `registry.gitlab.home.shdr.ch/so/orion/main:<sha>` and
   chart `oci://registry.gitlab.home.shdr.ch/so/orion/charts/orion` version
   `0.1.0-g<sha>`. Helm uses the existing local registry credentials. If the
   locked provider cannot resolve OCI, stop and prove the fix on disposable
   resources; do not switch production to a local chart path.
3. Obtain explicit approval for the existing `orion-prepull` DaemonSet
   create/delete recipe in Orion's deploy documentation. Pre-pull the chosen
   image on nodes using `orion-gitlab-registry`, wait for readiness, then
   remove the preparation DaemonSet after rollout. If the release contains
   migrations, take the required Barman backup before deployment.
4. Change only `orion_release` in
   `tofu/home/kubernetes/orion_release.tf`; chart version and image tag derive
   from it. Save the targeted plan and inspect its JSON before applying:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu plan -input=false -lock-timeout=120s -target=module.home.module.kubernetes.helm_release.orion -out=/tmp/orion-release.plan'
nix develop --command bash -c 'tofu -chdir=tofu show -json /tmp/orion-release.plan | jq -r ".resource_changes[] | select(.change.actions != [\"no-op\"]) | [.address, (.change.actions|join(\",\"))] | @tsv"'
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu apply -input=false /tmp/orion-release.plan'
```

Allow only the release's in-place update and explicitly reviewed dependencies;
reject unrelated changes. Run rollout, Agent/revision and existing-session
smoke checks. Image changes intentionally cause one Recreate rollout; a
chart-only no-op must not roll pods or revise Agents. Aether Secret-only
changes remain Aether changes and intentionally update `envChecksum`, which
can restart Orion. No release/checksum metadata is added to pod templates or
Agent specs beyond the existing environment checksum.

For amd64-only Orion images, add
`nodeSelector: {kubernetes.io/arch: amd64}` to the approved pre-pull
DaemonSet recipe. Without it the ARM nodes pull the image but fail its
`/bin/sh` init command with `exec format error`.

An explicitly approved `nix develop --command helm rollback orion <revision>
-n orion --wait` rolls back app and Agents together. Pin the corresponding
rollback SHA in Aether before the next apply; Helm rollback alone does not
update the declared release pin. First-install failure is not a rollback to
legacy Tofu owners and must never be handled by uninstall/reinstall.

## Instacart MCP Access

`litellm_config.yaml.tftpl` registers the in-cluster Instacart MCP; the
Orion chart owns its `instacart` grant. The `daimyo-orion` gateway key must
also list `instacart`. Update only that key, including its secret-loading
prerequisites, without reconciling other keys or deleting retired aliases:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token) ANSIBLE_CONFIG=./ansible/ansible.cfg; ansible-playbook ansible/playbooks/register_litellm_virtual_keys.yml --tags orion-mcp'
```

Reads, login and individual cart edits are allowed; `place_order`,
`clear_cart` and `instacart_logout` require approval in the Orion grant.
Instacart is deliberately absent from OpenWebUI's shared key scope.
Existing Daimyo sessions retain their pinned revision; use a new Orion
chat to receive the changed grant.

Cold-session MCP discovery is asynchronous: an immediate catalog lookup
may omit gateway tools before they finish connecting. The native status
device is `xd://mcp__instacart_instacart_status`.

Rollout evidence (2026-10-26): release
`6c8ee84c1703bd05208f8a0deb9ebb189b97dc9b`, Orion revision `r-38`.
The scoped key discovered all 14 tools; a native Orion status call returned
`logged_in: true` (task `01M5X7VWWHW2J1Z9DEMSPQ9RMK`).
An approval for `place_order` with `confirm: false` was opened and denied
(`01M5X8422B1RT49MR92FJ0E0QM`); no purchase was authorized.

## Home Assistant MCP Access

`litellm_config.yaml.tftpl` registers `homeassistant`, the loopback `ha-mcp`
sidecar in the LiteLLM pod; the Orion chart owns its `homeassistant` grant.
The `daimyo-orion` gateway key must also list `homeassistant` (same
`--tags orion-mcp` command as Instacart above). The gateway exposes all 77
tools as `homeassistant-<tool>`. The grant allows reads, `ha_bulk_control`
(device on/off/set, locks, media, scenes and scripts), todo items and calendar
events. The other 40 tools require approval: `ha_call_service` (its
`ws_command` sends any WebSocket command), `ha_call_event`, and every
automation, script, scene, dashboard, helper, label, area, zone, device,
entity, integration, app, HACS, backup, update, reload and restart tool. The
tool names were read from ha-mcp 9.0.0's `tools/list`; re-diff the grant when
the sidecar image changes. Home Assistant is deliberately absent from
OpenWebUI's shared key scope.

## Karakeep MCP Access

`litellm_config.yaml.tftpl` registers `karakeep`, the loopback
`karakeep-mcp` sidecar in the LiteLLM pod (`@karakeep/mcp` behind
supergateway), using a scoped Karakeep API key (SOPS `karakeep.mcp_api_key`:
bookmarks, highlights, lists and tags read-write, assets read). The Orion chart
owns its `karakeep` grant, and the `daimyo-orion` key lists `karakeep` (same
`--tags orion-mcp` command as Instacart above). Search, reading, bookmark,
highlight and tag edits and list membership run directly. `delete-bookmark`,
`delete-highlight`, `delete-list`, `delete-tag` and `update-list` (whose
`public` field publishes a list) ask first. The 29 tool names come from
`@karakeep/mcp` 0.34.0's `tools/list`; re-diff the grant when the package pin
changes.

Rollout evidence (2026-11-02): release
`81e39a63b79870e4963da5a8022f6358be9ee32f` carries both the `homeassistant`
and `karakeep` grants. A new Orion thread (`01M6EZQ64JXE00XR1RPFF6HT1N`) called
`ha_get_state` on `sun.sun` and Karakeep `get-lists` and answered from live
data.

## Withings MCP Access

The hosted `https://mcp.withings.com/mcp` is registered in LiteLLM as
`withings`, using the Withings+ account's OAuth login stored under machine
user `orion`. The `daimyo-orion` gateway key carries that user identity.
The public DCR Client ID is pinned in the gateway configuration; no client
secret is used. Start consent through LiteLLM's `/withings/authorize` so
the browser receives its state cookie. See [AI/ML](ai-ml.md) for the token
store and refresh verification.

The chart's shared Orion grant exposes 22 tools: 18 reads run directly;
`save_memories`, `delete_memories`, `log_symptoms` and `log_measures` require
approval. The existing YAML anchor gives the same grant to `orion-molecule`.

Rollout evidence (2026-11-03): release
`9ef28caa653f19d8fb696e3a41985eeea3fc2271` was pushed directly to Orion main,
without an MR. The same-SHA image-build, chart-check and chart-publish jobs
succeeded in pipeline `10670`. The approved temporary amd64 pre-pull
DaemonSet reached readiness and was deleted. The targeted OpenTofu release
plan updated only `helm_release.orion`; Orion rolled out ready with that
image, and both Agent resources compiled with the Withings grant.

A new Orion thread (`01M6GPNPJK27ADDEE7VERV3FE8`, session
`01M6GPNPCYBWZH29MYZPJRNYQM`) completed native `get_user_profile` and
`list_available_metrics` calls, returning 29 catalog entries. The initial
turn ran before background MCP discovery finished and could not see any
LiteLLM-backed tools; the following turn discovered and successfully used
Withings. No symptoms, measurements or Health Memory were written.

## PubMed MCP Access

`litellm_config.yaml.tftpl` registers `pubmed`, the loopback `pubmed-mcp`
sidecar in the LiteLLM pod: [cyanheads/pubmed-mcp-server](https://github.com/cyanheads/pubmed-mcp-server)
2.12.2 (`ghcr.io/cyanheads/pubmed-mcp-server:2.12.2@sha256:18a156d2...`, the
multi-arch index digest), native streamable HTTP on `127.0.0.1:8011/mcp`,
stateless, no auth and no secrets. It calls the NCBI E-utilities keyless (3
requests per second, paced by the server's own queue) so Orion reads PubMed
through the API instead of scraping `pubmed.ncbi.nlm.nih.gov`, which
reCAPTCHA-blocks Deskplane. Europe PMC and OpenAlex are fallbacks for full text
and related articles outside PMC; Unpaywall is off (`UNPAYWALL_EMAIL` unset).
All 12 tools are read-only (`readOnlyHint: true`), so the registry has no
`allowed_tools` list. The `daimyo-orion` key's scope includes `pubmed`
(same `--tags orion-mcp` command as Instacart above); no other key does.

The gateway exposes `pubmed-pubmed_search_articles`,
`pubmed-pubmed_fetch_articles`, `pubmed-pubmed_fetch_fulltext`,
`pubmed-pubmed_find_related`, `pubmed-pubmed_fetch_citation_metrics`,
`pubmed-pubmed_format_citations`, `pubmed-pubmed_spell_check`,
`pubmed-pubmed_lookup_mesh`, `pubmed-pubmed_lookup_citation`,
`pubmed-pubmed_convert_ids`, `pubmed-pubmed_europepmc_search` and
`pubmed-pubmed_europepmc_fetch`, read from `tools/list`; re-diff the Orion
grant when the image pin changes.

Gateway verification (2026-11-15, `daimyo-orion` key against
`/mcp/pubmed`): `tools/list` returned all 12 tools (`tool_count: 12`).
`pubmed_search_articles` for `tirzepatide obesity randomized controlled trial`
returned 209 matches (first page: PMIDs 38912654, 39536238, 40353578,
38078870, 39555826). `pubmed_fetch_articles` for PMID 35658024 (which direct
scrapes of `pubmed.ncbi.nlm.nih.gov` could not read) returned the
SURMOUNT-1 record, "Tirzepatide Once Weekly for the Treatment of Obesity",
with its full structured abstract, MeSH terms and NCT04184622.
`pubmed_find_related` (`cited_by`) returned 1,941 citing articles, and
`pubmed_fetch_fulltext` for PMC11598664 returned PMC body text. PMID
35658024 itself has no PMC copy, so its full-text lookup returned a typed
`no-epmc-fulltext` miss.

Rollout evidence (2026-11-15): Orion release `d6ca627efb46f1cffca39df51b8588f432cb0c7f` (Orion `main` and
`dev/revamp`; Coder gate `GATE_OK`, pipeline `13674` with image-build,
chart-check and chart-publish green) carries the `pubmed`, `ticketmaster` and
`shop` grants. The targeted plan for `helm_release.orion` changed only that
release in place; Helm revision 41 is deployed, the `orion` Deployment is ready
on `main:d6ca627e`, and Agents `orion` and `orion-molecule` are `Compiled`
with all three grants.
After the rollout, `daimyo-orion` against `/mcp/pubmed` called
`pubmed_fetch_articles` for PMID 35658024 and got the SURMOUNT-1 record with
NCT04184622 (`isError: false`).

## Ticketmaster MCP Access

`litellm_config.yaml.tftpl` registers `ticketmaster`, the loopback
`ticketmaster-mcp` sidecar in the LiteLLM pod:
[sourabhmadur/ticketmaster-mcp](https://github.com/sourabhmadur/ticketmaster-mcp)
at commit `bc3367d251e5d1877f7222d23826a2bbe2be383e`, installed from its commit
tarball (pip verifies `#sha256=4825ec19...`) with `mcp==1.30.0`,
`httpx==0.28.1` and `python-dotenv==1.2.4` pinned, on
`python:3.13-slim` by index digest. The server is stdio-only, so `mcp-proxy`
0.13.0 (its own venv, as for `comfy-mcp`) serves it as streamable HTTP on
`127.0.0.1:8012/mcp`. The repository has no license file (private use only).
The Discovery API consumer key is SOPS `ticketmaster.api_key`, injected as
`TICKETMASTER_API_KEY` from the `litellm-env` secret (5,000 requests per day,
5 per second); the consumer secret is not stored because Discovery does not use
it. The key is never a tool argument. It travels in the Discovery query string,
so the sidecar raises the `httpx` logger to WARNING; the container logs hold no
key. All 6 tools are read-only GETs, so the registry has no `allowed_tools`
list. The `daimyo-orion` key's scope includes `ticketmaster` (same
`--tags orion-mcp` command as Instacart above); no other key does. Nothing
touches Ticketmaster's OAuth, Partner or Commerce APIs, and there is no
purchase flow.

The gateway exposes `ticketmaster-search_events`,
`ticketmaster-get_event_details`, `ticketmaster-search_attractions`,
`ticketmaster-get_attraction_details`, `ticketmaster-search_venues` and
`ticketmaster-get_venue_details`, read from `tools/list`. The Orion grant
allows all six; re-diff it when the pin changes.

Gateway verification (2026-11-15, `daimyo-orion` key against
`/mcp/ticketmaster`): `tools/list` returned 6 tools (`tool_count: 6`).
`search_events` with `city: Toronto`, `country_code: CA`, a 14-day
`start_datetime`/`end_datetime` window and `sort: date,asc` returned `total:
267` with events carrying `id`, `name`, `url`, `start_local`,
`start_local_time`, `start_datetime`, `timezone`, `status`, `sales_public_*`,
`venue` (`id`, `name`, `city`, `state`, `country`, `address`, `postal_code`,
`lat`, `lng`), `attractions`, `classifications` and `price_ranges`. Season-pass
listings dated before the window (such as `rZ7HnEZ1AfGKxf`, TMU Bold Women's
Hockey) lead the date-sorted results; they are on sale through the window, and
concerts and games on 2026-11-15 to 2026-11-17 follow. A `classification:
music` search returned 135 matches. `get_event_details` for
`rZ7HnEZ1AfGKxf` returned the same fields plus `info`, `pleaseNote` and
`images`. `search_venues` (`Scotiabank Arena`, id `KovZpZAFFE1A`) and
`search_attractions` (`Raptors`, `K8vZ9171KC0` Toronto Raptors) also answered.

After the rollout (Helm revision 41, `d6ca627e`), `daimyo-orion` against
`/mcp/ticketmaster` ran `search_events` for Toronto (`city: Toronto`,
`country_code: CA`, `start_datetime`/`end_datetime` over the next 7 days,
`max_results: 3`): `total: 154`, three events with venue objects
(`isError: false`). The first attempt with the argument names
`start_date_time`/`size` returned zero events because the tool's real
parameters are `start_datetime`, `end_datetime` and `max_results`.

## Shop MCP Access

`litellm_config.yaml.tftpl` registers `shop`, the hosted Shop MCP at exactly
`https://mcp.shop.com/` (the root path; `/mcp` returns 404). It speaks MCP
protocol `2026-07-28` and opens with `server/discover`; LiteLLM v1.106.0-rc.1
defaults to the `initialize` handshake and Shop refuses it (`tools/list` came
back empty), so the entry sets `transport: http` and
`protocol_version: "2026-07-28"`. Each tool call is one stateless HTTP POST.
The registry has no `allowed_tools` list; the Orion grant carries the policy.
The `daimyo-orion` key's scope includes `shop` (same `--tags orion-mcp`
command as Instacart above).

The gateway exposes 21 tools as `shop-<tool>`: `search_catalog`,
`lookup_catalog`, `get_product`, `search_locations`, `lookup_locations`,
`ask_business`, `get_account`, `search_orders`, `get_order`, `get_cart`,
`create_cart`, `update_cart`, `get_checkout`, `create_checkout`,
`update_checkout`, `complete_checkout`, `create_spend_request`,
`get_spend_request`, `update_spend_request`, `cancel_spend_request` and
`complete_spend_request`. The Orion grant allows the catalog, product,
location, `ask_business`, `get_account`, `search_orders` and `get_order` reads
directly; every cart, checkout (including `complete_checkout`) and
spend-request tool, `get_spend_request` included, asks.

**Signed out only.** The gateway holds no Shop login yet: `get_account`,
`search_orders` and the spend-request tools answer Shop's own 401. The
blocker is the client identity. Shop's authorization server
(`https://accounts.shop.app`, scope `personal_agent`, resource
`https://mcp.shop.com`) has no dynamic client registration and documents
client ID metadata documents; against it, LiteLLM's metadata URL, claude.ai's
and vscode.dev's published ones all return `Unexpected server error
(invalid_client)` (checked twice on 2026-11-15, signed out), a non-URL id
returns `Unknown client`, and the CLI's public device-flow client
(`5c733ab2-...`) rejects LiteLLM's callback (`invalid_request`). LiteLLM has no
device-code flow. Shop documents refresh tokens only for a registered
application client with a secret; device-flow tokens expire and need the
shopper again. To finish the sign-in, the owner registers a Shop app in the Dev
Dashboard (callback = LiteLLM's `shop` callback, `personal_agent` scope, which
may need Shopify approval) and its client ID and secret go into SOPS and the
`shop` entry (`auth_type: oauth2`, `oauth2_flow: authorization_code`,
`upstream_resource: https://mcp.shop.com`); then the owner consents once at
`https://litellm.home.shdr.ch/shop/authorize`, as for Withings. Adding oauth2
makes signed-out reads answer 401 until that consent, so it is one step.
Until then Orion's prompt tells it to say the account tools are not connected.

Shop's skill is loaded at runtime, not vendored. Orion's prompt tells the agent
to scrape `https://mcp.shop.com/skill.md` (and `references/catalog.md` or
`transactions.md` when the skill points to them) before using the shop tools,
and says its owner's instructions and the approval policy win over the skill,
that Shop is signed out for now and that it must not offer to connect an
account. Deskplane's `scrape` returned HTTP 200 markdown for all three URLs
(2026-11-15). The skill is also reachable over MCP through the gateway
(`resources/read` of `skill://shop/SKILL.md` and `skill://shop/references/catalog.md`
via `/mcp/shop` with the `daimyo-orion` key), but the gateway's
`resources/list` is empty and `skills/list` answers `Method not found`, so
that path is not used.

Gateway verification (2026-11-15, `daimyo-orion` key against `/mcp/shop`):
`tools/list` returned 21 tools (`tool_count: 21`). `search_catalog` for
`heavyweight cotton t-shirt` (`catalog.query`, `context.address_country: CA`,
`pagination.limit: 3`) returned `ucp`, `products`, `messages`, `pagination`
and `next`, with products such as `gid://shopify/p/5e7L1QFrJGJEY0IPRDJJP`
("(New) Heavyweight Tee - Jet Black", CAD 40.00, rating 3.8) carrying `id`,
`title`, `description`, `handle`, `rating`, `media`, `options`, `metadata`,
`variants` and `price_range`. `get_product` on that id returned the product
with 1 variant (option `Size`; price CAD 4000 minor units, `available: true`,
seller Cove USA, `url`, `checkout_url`). `get_account` returned the
documented `401 Unauthorized` from `https://mcp.shop.com/`. No cart,
checkout or spend call was made.

Rollout evidence (2026-11-15): release `d6ca627efb46f1cffca39df51b8588f432cb0c7f` (Helm revision 41; see
the PubMed section for the gate, pipeline and Agent status). After it,
`daimyo-orion` against `/mcp/shop` ran `search_catalog` for `heavyweight cotton
t-shirt` (Canada context): "(New) Heavyweight Tee - Jet Black", CAD 40.00;
`get_account` answered Shop's 401, as documented. No cart, checkout or
spend-request call was made.

## Rogue Agent Access

Rogue retains `trust: external` and its Routeway model. It holds two network
grants: Deskplane's `search_web`, `scrape` and `parse_document`, authenticated
with a task token, and `qbittorrent` through the LiteLLM gateway with Orion's
gateway key (`orgs/personal/litellm-mcp`, held by the sidecar). The personal
Org's `externalAgents.allowedHosts` admits only `deskplane-mcp.deskplane.svc`
and `litellm.litellm.svc.cluster.local`; it is not unrestricted pod internet
access. Shell access, logged-in browser tools, memory and agent delegation
remain off.

Rogue asks before `delete_torrent`, `cleanup_completed`, `mass_rename`,
`rename_folder`, `edit_tracker`, `remove_trackers`, `uninstall_search_plugin`
and `ban_peers`; the gateway side of the qBittorrent MCP is described in
[AI/ML](ai-ml.md). The grant and prompt live in `orion.tf`, tool lists in
`orion_agent_tools.tf`, the Org host allowlist in `daimyo.tf`, and the key's
server scope in `register_litellm_virtual_keys.yml` (`--tags orion-mcp`).
New Rogue chats use revision `r-7`; existing chats retain their previous
revision.

Verified with a real Rogue search and an HTTP 200 scrape of
`https://www.iana.org/help/example-domains`
(task `01M5XGB4ATPQVQQDDW0PFA6NFJ`), and on 2026-10-31 with a read-only
qBittorrent ratio query answered from live data
(task `01M69QMW29PGWYTE302DZ0DVG7`).
