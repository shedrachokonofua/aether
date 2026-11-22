# Orion

Orion is the personal AI dashboard and start page at `home.shdr.ch`, built
from `so/orion`. The Orion chart (in that repo) owns Deployment/Service `orion`
and the `orion`, `orion-molecule`, `coordinator`, `orion-runner` and
`orion-feed-*` Agents with their grants, prompts and the `orion-skills`
bundle. Aether owns everything around it: the Helm release and its pin,
namespaces, Secrets, PVCs, CNPG and backups, egress, HTTPRoute, QA browser,
Keycloak, Cedar, CRDs, the `dev`, `notes-keeper` and Rogue Agents, and the
LiteLLM gateway MCPs Orion's grants point at.

Run every command from the Aether root inside `nix develop --command`, after
`task login:status` and with `kubectl config current-context` printing
`admin@aether-k8s`.

## Releases

The release procedure (Coder gate, fast-forward pushes, CI artifacts, image
pre-pull) is in the Orion repo's README, "Normal releases after adoption".
Aether's part is the pin: change only `orion_release` in
[`orion_release.tf`](../tofu/home/kubernetes/orion_release.tf) (image tag and
chart version `0.1.0-g<sha>` both derive from it), then save, review and apply
a targeted plan:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu plan -input=false -lock-timeout=120s -target=module.home.module.kubernetes.helm_release.orion -out=/tmp/orion-release.plan'
nix develop --command bash -c 'tofu -chdir=tofu show -json /tmp/orion-release.plan | jq -r ".resource_changes[] | select(.change.actions != [\"no-op\"]) | [.address, (.change.actions|join(\",\"))] | @tsv"'
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token); tofu -chdir=tofu apply -input=false /tmp/orion-release.plan'
```

- The plan may only update `helm_release.orion` in place.
- An image change causes one Recreate rollout. Secret changes in aether change
  `envChecksum` and restart Orion too.
- Orion images are amd64-only: the pre-pull DaemonSet needs
  `nodeSelector: {kubernetes.io/arch: amd64}`, or ARM nodes fail its init
  command with `exec format error`.
- Rollback: `helm rollback orion <revision> -n orion --wait` reverts app and
  Agents together; pin the matching SHA here before the next apply.
- The release still has `atomic = false` and `cleanup_on_fail = false` from the
  Helm adoption; never uninstall/reinstall to fix a failed release. The
  `removed` blocks in `orion.tf` are adoption history.

Rollout evidence (2026-11-21): release
`5f6b20c17e39feec0455ada833569504d37ff5f3` (browser guidance in the `orion`
prompt and eleven more Deskplane tools in its `web` grant: `browser_click`,
`browser_fill`, `browser_type`, `browser_press`, `browser_select`,
`browser_check`, `browser_scroll`, `browser_wait`, `browser_is`,
`browser_dialog`, `browser_tabs`) passed `GATE_OK` and pipeline `15578`
(image-build, chart-check, chart-publish; its three `visual-qa` shards were
cancelled, since that job is allowed to fail and had failed on every `main`
pipeline since 2026-11-18). After the amd64 pre-pull on 4 of 4 nodes, the
targeted plan changed only `helm_release.orion` (Helm revision 59). The live
`orion` Agent lists all eleven tools and `/login` answers 200.

Later the same day release `b3562c04c49a3f05c75f79927be9003362673577` followed
(`home_post` and `home_cards` on the threads MCP and in the `orion` grant,
`orion-skills` version 10 with the Pharos "Thinking with his books" section,
and the Workers-panel fix): `GATE_OK` with 2,954 tests, pipeline `15685`, the
same pre-pull, Helm revision 60, only `helm_release.orion` changed. The live
`orion` Agent lists both tools and pins bundle version 10. Neither tool had
been called from a real thread when this was written.

Release `1b6416943c48cfc587bd6eebd5a641e57401601f` (also 2026-11-21) added
follow-ups: `followup_create` (policy `ask`), `followups` and `followup_stop`
in the `orion` threads grant, and a fourteenth Agent, `orion-feed-mail`, which
runs `mail-` follow-up topics with the mnemo search tools and no web tools.
`GATE_OK` with 2,957 tests, pipeline `15713`, Helm revision 61. The same plan
changed `orion_agent_egress` so that `orion` and `orion-feed-mail` task pods
may reach `mnemo.home.shdr.ch`; no other resource changed. The live Agents
show those grants and the policy selects both. No follow-up had been created
or run when this was written, so the mail runner's access to mnemo is
configured, not yet observed.

Release `8612f1866d374dca1a50a4692baeb986cc0ff4a8` (2026-11-22) lets an
`orion-table` block have a blank column header; before it a table whose first
column was `""` showed the error callout instead of the table (thread
`01M81BE221RAC55NTEAR09HCVG`). It also adds `docs/generative-ui-prior-art.md`
to the Orion repository. `GATE_OK` with 2,958 tests on the second run (the
first failed one unrelated migration test), pipeline `15995`, Helm revision
62; only `helm_release.orion` changed. The fix is covered by a test with the
failing shape; the live thread was not opened to see it.

## Database Storage

`orion-cnpg` uses a 50 GiB `ceph-rbd` volume for data and WAL
(`kubectl_manifest.orion_cnpg_cluster` in `orion.tf`). It was 5 GiB until
2026-11-08, when it filled; the Cluster change alone did not grow the PVC, so
the PVC was resized by hand.

## Gateway MCPs

Orion's LiteLLM-backed grants (`<server>-<tool>` names, URL
`http://litellm.litellm.svc.cluster.local:4000/mcp/<server>`) authenticate with
the `daimyo-orion` virtual key, which only the Daimyo sidecar holds (OpenBao
`kv/orgs/personal/litellm-mcp`). The servers are registered in
`litellm_config.yaml.tftpl`; sidecars run in the LiteLLM pod (`litellm.tf`) on
loopback. A new server needs the sidecar and registry entry applied (targeted
plan on the litellm and openwebui deployments and the `litellm-config` and
`litellm-env` secrets; it restarts LiteLLM), then the key scope:

```bash
nix develop --command bash -c 'export VAULT_ADDR=https://bao.home.shdr.ch VAULT_TOKEN=$(cat ~/.aether-toolbox/bao/token) ANSIBLE_CONFIG=./ansible/ansible.cfg; ansible-playbook ansible/playbooks/register_litellm_virtual_keys.yml --tags orion-mcp'
```

That play updates only the `daimyo-orion` key. Grant tool lists come from the
gateway's `tools/list`: re-diff the Orion grant when a pin changes. Existing
Daimyo sessions keep their Agent revision, so a changed grant needs a new chat,
and a cold session's first turn may run before MCP discovery finishes.

| Server | Runs as | Secrets | Gateway allowlist |
| --- | --- | --- | --- |
| `instacart` | `instacart-mcp` Service (holds its own login) | none at the gateway | none |
| `homeassistant` | `ha-mcp` sidecar | `homeassistant.telemetry_token` | none |
| `karakeep` | `@karakeep/mcp` via supergateway | `karakeep.mcp_api_key` | none |
| `nextcloud` | `cbcoutinho/nextcloud-mcp-server` 0.213.2, `:8017` | `random_password.nextcloud_mcp_app_password` (app password on Shedrach's account) | none (55 tools: Files, Sharing, Calendar, Contacts) |
| `withings` | hosted `mcp.withings.com` | OAuth login of LiteLLM user `orion` | none |
| `pubmed` | `cyanheads/pubmed-mcp-server` 2.12.2, `:8011` | none (keyless E-utilities) | none |
| `ticketmaster` | `sourabhmadur/ticketmaster-mcp` `bc3367d` via mcp-proxy, `:8012` | `ticketmaster.api_key` | none |
| `openfda` | `cyanheads/openfda-mcp-server` 0.10.0, `:8013` | none (1,000 requests/day) | 12 tools, no `openfda_dataframe_*` |
| `openalex` | `cyanheads/openalex-mcp-server` 0.11.1, `:8014` | `openalex.api_key` ($1/day budget) | none |
| `annas` | `iosifache/annas-mcp` v0.1 via mcp-proxy, `:8016` | `annas_archive.secret_key` | 4 search/download tools; downloads ask in Orion |
| `yourspotify` | `pentafive/your-spotify-mcp` `9e0e606` via supergateway, `:8015` | `yourspotify.mcp_public_token` | 13 read tools |
| `shop` | hosted `mcp.shop.com` | none (signed out) | none |
| `pharos` | Service `pharos` in namespace `pharos`, over cluster DNS | the Pharos MCP token (`random_password.pharos_mcp_token`, also OpenBao `kv/pharos/mcp`) | none (9 read-only tools) |

Approval policy lives in the Orion grants, not the gateway. Server notes:

### Instacart

`instacart_mcp.tf` runs `so/instacart-mcp:latest` with a persistent browser
profile; a pod-template change (or a new pod) pulls the current `latest`.
`TOOL_TIMEOUT_SECONDS=50` stops any tool call that has not answered, below the
gateway's 60 s; a stopped call answers `ToolTimeout`, and `/healthz` fails when
the session lock is held past every deadline, so the liveness probe restarts
the pod. On 2026-11-22 the pod, up 21 days, accepted every call and answered
none (all tools wait on one lock and had no deadline); the `orion` agent's
calls timed out at the gateway. Rolled out that day with instacart-mcp
`3809bd1`: `instacart_status` then answered in 11 s (logged in) and a product
search in 9 s, called directly at `instacart-mcp.home.shdr.ch/mcp`. Which call
hung first was not established.

### Home Assistant

ha-mcp's `ha_call_service` can send any WebSocket command, so it and every
configuration tool ask; `ha_bulk_control`, reads, todos and calendar events
run directly.

### Nextcloud

`litellm_config.yaml.tftpl` registers `nextcloud`, the loopback `nextcloud-mcp`
sidecar in the LiteLLM pod: [cbcoutinho/nextcloud-mcp-server](https://github.com/cbcoutinho/nextcloud-mcp-server)
0.213.2 (`ghcr.io/cbcoutinho/nextcloud-mcp-server:0.213.2@sha256:655c2864...`,
the multi-arch index digest), native streamable HTTP on `127.0.0.1:8017/mcp`
with no auth on the listener, started with one `--enable-app` flag each for
`webdav`, `sharing`, `calendar` and `contacts`. It reaches Nextcloud at
`http://nextcloud-server.nextcloud.svc.cluster.local` and signs in as Shedrach's
own Nextcloud account (uid `f843d136dcb36f7fbf3699c26ae9dfaa12d8d0637ca9ee4335f1da1c1264b02a`,
`local.nextcloud_mcp_uid`; the hashed id predates `--unique-uid=0`) with a
dedicated app password named `orion-mcp (litellm nextcloud-mcp)`. The `daimyo-orion`
key's scope includes `nextcloud` (same `--tags orion-mcp` command as Instacart
above); no other key does.

Orion therefore reaches all of his files, shares, calendars, task lists and
address books, and nothing needs sharing. The account is in Nextcloud's `admin`
group, but the sidecar registers only the Files, Sharing, Calendar and Contacts
tools. The `nextcloud_mcp_bootstrap` Job installs the Calendar, Contacts and
Tasks apps and creates the app password from
`random_password.nextcloud_mcp_app_password` (40 characters, tofu state; Secret
`nextcloud-mcp` key `MCP_APP_PASSWORD` in namespace `nextcloud`, and
`NEXTCLOUD_MCP_PASSWORD` in `litellm-env`). It writes the token through
Nextcloud's token provider in a `php -r` snippet, so the value never reaches
argv; if a token of that name with a different value exists it is revoked
first, so rotating the `random_password` replaces the app password on the next
apply. There is no SOPS secret. To cut Orion's access, revoke `orion-mcp
(litellm nextcloud-mcp)` under Settings > Security > Devices & sessions. The
Job creates no `tasks` list: his account already has `personal` and `tasks`.

The gateway exposes the server's 55 tools as `nextcloud-<tool>`: 24 Files
(`nc_webdav_*`), 6 Sharing (`nc_share_*`), 17 Calendar including todos
(`nc_calendar_*`) and 8 Contacts (`nc_contacts_*`). The sidecar registers only
those four groups, so the registry has no `allowed_tools` list. The Orion chart's `nextcloud` grant
runs 42 directly: every read, plus the additive or reversible writes
`nc_webdav_write_file`, `nc_webdav_edit_file`, `nc_webdav_create_directory`,
`nc_webdav_copy_resource`, `nc_webdav_create_comment`, `nc_webdav_tag_file`,
`nc_webdav_untag_file`, `nc_webdav_restore_from_trash`,
`nc_webdav_restore_version`, `nc_calendar_create_event`,
`nc_calendar_update_event`, `nc_calendar_create_todo`,
`nc_calendar_update_todo`, `nc_calendar_complete_todo`,
`nc_contacts_create_addressbook`, `nc_contacts_create_contact` and
`nc_contacts_update_contact`. `nc_webdav_write_file` fails closed: it creates
new files and overwrites only with the etag from a prior read or an explicit
`if_match="*"`. Thirteen ask first: deletes (`nc_webdav_delete_resource`,
`nc_calendar_delete_event`, `nc_calendar_delete_todo`,
`nc_contacts_delete_contact`, `nc_contacts_delete_addressbook`), moves
(`nc_webdav_move_resource`), share changes including public links
(`nc_share_create`, `nc_share_create_public_link`, `nc_share_update`,
`nc_share_delete`), `nc_calendar_bulk_operations`, `nc_calendar_manage_calendar`
and `nc_calendar_create_meeting`, which takes attendee email addresses: they
destroy data, change who can read it, or message other people. The
tool names come from 0.213.2's `tools/list` with those four apps; re-diff the
grant when the image pin changes.

Local verification (2026-11-17): the sidecar image, against a throwaway
`nextcloud:34.0.5-apache` container with `overwritehost` and `overwriteprotocol`
set as in production and a local `orion` account, returned 55 tools from
`tools/list`. `nc_webdav_list_directory`, `nc_webdav_write_file` (201, and a
second write to the same path was refused), `nc_webdav_read_file`,
`nc_calendar_list_calendars`, `nc_calendar_create_event`,
`nc_calendar_get_upcoming_events`, `nc_contacts_list_addressbooks` and
`nc_share_list` succeeded. `nc_calendar_create_todo` returned 403 on `personal`
and succeeded on a `tasks` list created with `occ dav:create-calendar`. Idle
memory was about 180-216 MiB.

Gateway verification (2026-11-17, `daimyo-orion` key against
`/mcp/nextcloud`, signed in as Shedrach's account): `tools/list` returned all
55 tools. `nc_webdav_list_directory` on `/` returned his 7 entries,
`nc_calendar_list_calendars` returned `personal`, `contact_birthdays` and
`tasks`, `nc_contacts_list_addressbooks` returned 3 address books, and
`nc_calendar_list_todos` on `tasks` and `nc_share_list` succeeded. No write
tool was called.

Rollout evidence (2026-11-18): release
`fc3dc284c8361587e89530d7cb9de238a26b125c` carries the `nextcloud` grant.
Gate `GATE_OK`; image-build, chart-check and chart-publish succeeded in
pipeline `14176`. The approved amd64 pre-pull DaemonSet reached readiness and
was deleted. The targeted release plan (run with `-refresh=false`, because
the Google WIF login had expired) changed only `helm_release.orion`: chart
version and image tag. Orion rolled out ready on that image (Helm revision
52), and Agents `orion` and `orion-molecule` are Compiled and Ready with the
55-tool grant, 13 of them `ask`. No Orion thread has called a Nextcloud tool
yet.

### Withings

Consent starts at `https://litellm.home.shdr.ch/withings/authorize` so the
browser gets LiteLLM's state cookie; the public DCR client ID is pinned in the
registry entry. Token storage and refresh are in [AI/ML](ai-ml.md).

### PubMed

Orion reads PubMed through this server because Deskplane scrapes of
`pubmed.ncbi.nlm.nih.gov` hit reCAPTCHA. Europe PMC and OpenAlex are its
full-text fallbacks; Unpaywall is off.

### Ticketmaster

The server is stdio-only and has no license file (private use). The Discovery
key travels in the query string, so the sidecar sets the `httpx` logger to
WARNING. Search arguments are `start_datetime`, `end_datetime` and
`max_results`.

### OpenFDA

`CANVAS_PROVIDER_TYPE=none` turns DataCanvas off, but 0.10.0 still lists the
`openfda_dataframe_*` tools (they answer `canvas_disabled`), hence the
allowlist.

### OpenAlex

`OPENALEX_API_KEY` comes from `litellm-env`; `OPENALEX_MAILTO` is unset.

### Anna's Archive

The stdio server runs behind the same loopback mcp-proxy bridge as Ticketmaster.
Release archives are SHA-256 checked for amd64 and arm64. The membership key
comes from `litellm-env`, never a tool argument. The mirror is pinned to
`annas-archive.gl`; automatic third-party mirror discovery is off.

Downloads go to `/downloads` on PVC `litellm/annas-downloads`: `ReadWriteMany`,
`nfs-hdd`, provisioned under the HDD export `/mnt/hdd/data`. Its 50 GiB request
is not an NFS quota. The StorageClass retains the data and the claim has
`prevent_destroy`; pod replacement does not remove downloads.

Downloads consume the membership's daily allowance, so both download tools
ask for approval. Upstream returns only the destination directory, not the
file contents; it does not make files available in Orion's workspace. Public
search and DOI lookup depend on the website and can hit DDoS-Guard even when
the membership download API works. Upstream can misreport a blocked search as
no results; it is not evidence that the archive lacks the requested work.

### Your Spotify

The server is not on npm: the sidecar downloads the commit tarball, checks its
sha256, builds it and serves it with supergateway, so a cold start needs
GitHub and npm. It reads the in-cluster Your Spotify API with the dashboard's
public token (sent as `?token=`). Without Spotify Web API credentials its
playback and playlist tools never load; the allowlist also drops the account
writes and `analyze_affinity`, which needs a logged-in web session.

### Shop

The registry entry is exactly `https://mcp.shop.com/` (`/mcp` is 404) with
`transport: http` and `protocol_version: "2026-07-28"`, because Shop refuses
LiteLLM's default `initialize` handshake. The gateway holds no Shop login:
account, order and spend-request tools answer 401. Shop's authorization
server has no dynamic client registration and rejects every client ID
metadata document tried, and LiteLLM has no device flow, so signing in needs a
Shop app registered in the Dev Dashboard (callback = LiteLLM's `shop`
callback, `personal_agent` scope), its ID and secret in SOPS and the entry
(`auth_type: oauth2`, `oauth2_flow: authorization_code`,
`upstream_resource: https://mcp.shop.com`), then one consent at
`https://litellm.home.shdr.ch/shop/authorize`. Orion fetches Shop's skill from
`https://mcp.shop.com/skill.md` at runtime.

### Pharos

The registry entry is `http://pharos.pharos.svc.cluster.local:8080/mcp/` with
`transport: http`; the trailing slash is the MCP mount. The gateway acts as
the single Pharos MCP identity, which reads every book in the library.
`pharos_find_skills` and `pharos_load_skill` serve each finished book as an
Agent Skill (a `SKILL.md` and one file per chapter); `pharos_search_ideas`
searches the ideas of every book at once; the other six tools read chapters,
single ideas and the books' exact text, and `pharos_ask` runs the local
model. The `orion` and `orion-molecule` Agents hold a `pharos` grant for the
tools (eight from Orion release `d12bd301`, with `pharos_search_ideas` from
`fb051169`), and the built-in skill `pharos-library` (Orion chart,
`orion-skills` version 8) tells the agent to search ideas for a topic, or to
find a book and load it. See [AI/ML](ai-ml.md#pharos).

## Polymarket Task Egress

Org `personal` task pods reach `gamma-api.polymarket.com` and
`clob.polymarket.com` over HTTPS (`daimyo_personal_polymarket_fqdns` in
`daimyo.tf`, in both the DNS allowlist and `daimyo_tasks_egress`) for Orion's
`polymarket` skill.

## YouTube Task Egress

Org `personal` task pods reach `www.youtube.com` over HTTPS
(`daimyo_personal_youtube_fqdns` in `daimyo.tf`, in both the DNS allowlist and
`daimyo_tasks_egress`) for Orion's `youtube-content` skill, which reads video
transcripts from the watch page, the Innertube player API and the timedtext
captions, all on that host. YouTube did not block the cluster's home IP when
tested from a pod on 2026-11-18.

Rollout evidence (2026-11-19): release
`c9268ac59e5b156b67683452c93ea68eccbf4684` (`orion-skills` version 9, with
`bee58910`'s prompt change) passed `GATE_OK` and pipeline `14942`. Targeted
tofu plans for both `daimyo_tasks_egress["personal"]` and `helm_release.orion`
also pulled in `talos_machine_configuration_apply` on all eight nodes and the
LiteLLM Deployment and Secrets: live carries aether work not yet on `main`, and
applying from `main` would undo it. Neither plan was applied. The CiliumNetworkPolicy
got the two rendered additions by server-side apply (field manager `Terraform`,
as tofu applies it). Orion was upgraded with `helm upgrade` from the published
OCI chart `0.1.0-gc9268ac5…` and the live values, with only `image.tag` changed
(Helm revision 54), after the amd64 pre-pull. Both match this commit's
`orion_release` and `daimyo.tf`, so the next tofu plan sees no spec change for
either. A live `orion` session read `skill://youtube-content`, fetched the
TED transcript from its task pod and cited the 7:22 timestamp.

## Rogue Agent Access

Rogue keeps `trust: external` and its Routeway model. It has Deskplane's
`search_web`, `scrape` and `parse_document` (task token) and `qbittorrent`
through the gateway with the `daimyo-orion` key. The personal Org's
`externalAgents.allowedHosts` admits only `deskplane-mcp.deskplane.svc` and
`litellm.litellm.svc.cluster.local`. Shell, logged-in browser tools, memory and
delegation are off, and destructive qBittorrent tools ask. The grant and
prompt are in `orion.tf`, tool lists in `orion_agent_tools.tf`, the host
allowlist in `daimyo.tf`, and the key scope in
`register_litellm_virtual_keys.yml`.
