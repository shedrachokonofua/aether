# Hermes Access Plan

Hermes runs two separate agents with different trust boundaries.

## Beryl

Beryl is the private offline personal assistant.

| Area | Access | Status |
| --- | --- | --- |
| Local LLM | llama-swap only | Wired |
| Matrix | Beryl bot account via stored access token, private home room for proactive output | Wired |
| Jellyfin | Beryl-specific API key | Wired |
| Notes and documents | AFFiNE via community `affine-mcp-server` on LiteLLM MCP | Wired |
| LiteLLM MCP | Full aggregate (time, firecrawl, finviz, alpha_vantage, affine, …) | Wired |
| Images and screenshots | Private read/search workspace with local vision | To wire |
| Home Assistant | Limited bot token through Hermes native HA tools + gateway platform with narrow event filters | Wired |
| Web/Firecrawl/cloud APIs | SearXNG + Firecrawl extract + LiteLLM MCP sidecars | Wired |
| Browser automation | Hermes local browser tooling only; Firecrawl browser cloud mode is not wired to self-host Firecrawl | Limited |
| Infra/media/admin systems | None | Policy documented |

## Tungsten

Tungsten is the online development and operations bot.

| Area | Access | Status |
| --- | --- | --- |
| LiteLLM/cloud model | Hermes Tungsten virtual key | Wired |
| Matrix | Tungsten bot account via stored access token | Wired |
| Firecrawl/web research | Firecrawl API key | Wired |
| Grafana | Read-only service account token | Wired as env |
| Arr stack | `mcp-arr` stdio MCP for Sonarr/Radarr/Lidarr/Prowlarr | Wired |
| qBittorrent | URL + credentials for diagnostics | Wired as env |
| SABnzbd | URL + API key | Wired as env |
| Jellyfin | Tungsten-specific API key | Wired |
| Kubernetes | Read-only service account for objects, events, logs, metrics | Wired |
| GitLab | Bot PAT + bundled `gitlab` skill (curl API, search/clone/MR) | Wired |
| OpenBao | Narrow read only to explicit paths | Not wired |

## Needed From Shdrch

- Decide where Beryl's notes/images live and whether those mounts should be
  read-only. Proposed paths inside the pod: `/private/notes` and
  `/private/images`.

## Online References

- Hermes native MCP config uses `mcp_servers` in `config.yaml`; tools are
  registered as `mcp_<server>_<tool>`.
- Beryl connects to the LiteLLM MCP aggregate at `litellm.infra.svc.cluster.local:4000/mcp`
  with a dedicated virtual key (`litellm.virtual_keys.hermes_beryl` in SOPS).
- `mcp-arr` provides a unified MCP server for Sonarr, Radarr, Lidarr, and
  Prowlarr (Tungsten only).
- Hermes Home Assistant support is gated by `HASS_TOKEN`. Beryl uses the native
  `ha_list_entities`, `ha_get_state`, `ha_list_services`, and `ha_call_service`
  tools plus the Hermes `platforms.homeassistant` gateway adapter; this is
  separate from Home Assistant's MCP endpoint.
- Beryl's Home Assistant event intake is intentionally narrow:
  `alarm_control_panel` and `climate` domains, plus specific Q Sensor/diffuser
  maintenance entities. It does not use `watch_all` or subscribe to all lights,
  motion, presence, or telemetry events.
- Tungsten GitLab workflows use `GITLAB_TOKEN`/`GITLAB_URL` in the terminal shell
  plus bundled skill `hermes/tungsten/skills/gitlab/SKILL.md` (adapted from
  vm0-ai/vm0-skills; no GitLab MCP).
- Matrix is wired with `MATRIX_ACCESS_TOKEN` for each bot rather than password
  login, so pod restarts do not trip homeserver login rate limits.
- Beryl's Matrix home room is configured through `MATRIX_HOME_ROOM`; the same
  room is also used as `MATRIX_ALLOWED_ROOMS` so proactive output and user
  interaction stay in the private Shdrch/Beryl room unless code changes expand
  the allowlist.
- Beryl should use the home room for scheduled briefings, reminders, and
  filtered event notifications. The intended pattern is high-signal and
  low-spam: run or prove a workflow manually first, then schedule it when the
  cadence is clear.
- Beryl does not set `browser.cloud_provider`. Firecrawl browser cloud mode in
  Hermes expects the Firecrawl `/v2/browser` API, but upstream self-host
  Firecrawl currently requires an external `BROWSER_SERVICE_URL` and DB-backed
  browser session persistence for that path. Keep `firecrawl.home.shdr.ch` for
  `/v2/scrape`, `/v2/search`, and MCP only unless official self-host browser
  service wiring is added.
