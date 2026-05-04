# Hermes Access Plan

Hermes runs two separate agents with different trust boundaries.

## Beryl

Beryl is the private offline personal assistant.

| Area | Access | Status |
| --- | --- | --- |
| Local LLM | llama-swap only | Wired |
| Matrix | Beryl bot account via stored access token | Wired |
| Jellyfin | Beryl-specific API key | Wired |
| Notes and documents | Private read/search workspace | To wire |
| Images and screenshots | Private read/search workspace with local vision | To wire |
| Home Assistant | Limited bot token through Hermes native HA REST tools | Wired |
| Web/Firecrawl/cloud APIs | None by default | Firecrawl removed from Beryl wiring |
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
| GitLab | Bot PAT for repos, MRs, CI | Wired as env |
| OpenBao | Narrow read only to explicit paths | Not wired |

## Needed From Shdrch

- Decide where Beryl's notes/images live and whether those mounts should be
  read-only. Proposed paths inside the pod: `/private/notes` and
  `/private/images`.

## Online References

- Hermes native MCP config uses `mcp_servers` in `config.yaml`; tools are
  registered as `mcp_<server>_<tool>`.
- `mcp-arr` provides a unified MCP server for Sonarr, Radarr, Lidarr, and
  Prowlarr.
- Hermes also ships native Home Assistant REST tools gated by `HASS_TOKEN`;
  Beryl uses those instead of the HA MCP endpoint.
- Matrix is wired with `MATRIX_ACCESS_TOKEN` for each bot rather than password
  login, so pod restarts do not trip homeserver login rate limits.
