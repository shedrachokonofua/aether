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
| `withings` | hosted `mcp.withings.com` | OAuth login of LiteLLM user `orion` | none |
| `pubmed` | `cyanheads/pubmed-mcp-server` 2.12.2, `:8011` | none (keyless E-utilities) | none |
| `ticketmaster` | `sourabhmadur/ticketmaster-mcp` `bc3367d` via mcp-proxy, `:8012` | `ticketmaster.api_key` | none |
| `openfda` | `cyanheads/openfda-mcp-server` 0.10.0, `:8013` | none (1,000 requests/day) | 12 tools, no `openfda_dataframe_*` |
| `openalex` | `cyanheads/openalex-mcp-server` 0.11.1, `:8014` | `openalex.api_key` ($1/day budget) | none |
| `annas` | `iosifache/annas-mcp` v0.1 via mcp-proxy, `:8016` | `annas_archive.secret_key` | 4 search/download tools; downloads ask in Orion |
| `yourspotify` | `pentafive/your-spotify-mcp` `9e0e606` via supergateway, `:8015` | `yourspotify.mcp_public_token` | 13 read tools |
| `shop` | hosted `mcp.shop.com` | none (signed out) | none |
| `pharos` | Service `pharos` in namespace `pharos`, over cluster DNS | the Pharos MCP token (`random_password.pharos_mcp_token`, also OpenBao `kv/pharos/mcp`) | none (8 read-only tools) |

Approval policy lives in the Orion grants, not the gateway. Server notes:

### Home Assistant

ha-mcp's `ha_call_service` can send any WebSocket command, so it and every
configuration tool ask; `ha_bulk_control`, reads, todos and calendar events
run directly.

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
Agent Skill (a `SKILL.md` and one file per chapter); the other six tools read
chapters, ideas and the books' exact text, and `pharos_ask` runs the local
model. See [AI/ML](ai-ml.md#pharos).

## Polymarket Task Egress

Org `personal` task pods reach `gamma-api.polymarket.com` and
`clob.polymarket.com` over HTTPS (`daimyo_personal_polymarket_fqdns` in
`daimyo.tf`, in both the DNS allowlist and `daimyo_tasks_egress`) for Orion's
`polymarket` skill.

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
