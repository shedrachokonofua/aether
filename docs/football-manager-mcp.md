# Football Manager MCP

MCP tools that read and edit a live Football Manager 26 career running in the
`game-server` pod (`games` namespace, `tofu/home/kubernetes/game_server.tf`). No
screen automation: a BepInEx plugin inside FM drives FM's own data-binding and
command layers, and an MCP server in a sidecar exposes that as tools.

```mermaid
flowchart LR
  client[MCP client] --> litellm[LiteLLM MCP gateway<br/>server "fm"]
  litellm -->|bearer token| sidecar[fm-mcp sidecar<br/>:18766 /mcp]
  sidecar -->|127.0.0.1:18765| plugin[FM Bridge plugin<br/>inside fm.exe]
  plugin --> fm[FM26 managed UI layer<br/>→ native game_plugin.dll]
```

## Where things live

| Piece | Location | Managed by |
|---|---|---|
| FM26 install | games PVC: `/mnt/games/GameLibrary/Steam/steamapps/common/Football Manager 26` (Proton Hotfix) | Steam |
| BepInEx 6.0.0-be.738 (Thunderstore `BepInExPack_FootballManager26`) | FM install dir; installed file list in `~/fm-mcp/vendor/bepinex-installed-files.txt` | manual |
| `winhttp` override (loads BepInEx under Proton) | prefix `user.reg`, key `AppDefaults\fm.exe\DllOverrides`; pre-change copy `~/fm-mcp/vendor/user.reg.pre-bepinex` | manual |
| BepInEx console disabled | `BepInEx/config/BepInEx.cfg` (`[Logging.Console] Enabled = false`); original in `~/fm-mcp/vendor/BepInEx.cfg.orig` | manual |
| FM Bridge plugin source | GitLab `so/fm-mcp` → `plugin/` (C#, net6.0); built in the pod's `~/fm-mcp/plugin` → `BepInEx/plugins/FmBridge/FmBridge.dll` | git |
| MCP server source | GitLab `so/fm-mcp` → `mcp/` (TypeScript, `@modelcontextprotocol/sdk` 1.32.1); built in the pod's `~/fm-mcp/mcp` | git |
| MCP sidecar, Service `fm-mcp`, token secret | `game_server.tf` | tofu |
| LiteLLM registration | `litellm_config.yaml.tftpl` (`mcp_servers.fm`), OpenWebUI list in `register_litellm_virtual_keys.yml` | tofu / ansible |

`~` is `/home/default` on the home PVC. Source of truth is
[`so/fm-mcp`](https://gitlab.home.shdr.ch/so/fm-mcp); `~/fm-mcp` in the pod is
a build checkout that `scripts/sync-build.sh` overwrites, so don't commit there.
The home PVC has `backup = none` (`namespace_contracts.tf`): the save backups
(`~/fm-mcp-backups/`) and the gitignored `vendor/` originals exist only there.

The .NET 8 SDK (`~/.dotnet`) and Cpp2IL (`~/fm-mcp/tools`) also live on the
home PVC. `~/fm-mcp/dump` holds a Cpp2IL diffable-C# dump of FM26's IL2CPP
metadata (signatures only; regenerate after FM updates).

## Development loop

Edit a clone of `so/fm-mcp` on a workstation, then:

- `scripts/sync-build.sh plugin|mcp|all`: tar the working copy into
  `~/fm-mcp` in the pod and build there (`dotnet build` / `npm run build`).
  Fails on build errors.
- `scripts/deploy-plugin.sh [--force] [--reload|--no-reload]`: install the
  plugin DLL and restart FM through Steam (BepInEx cannot hot-reload). Refuses
  while a save is loaded unless `--force`; after a forced restart it reloads
  FM's last save automatically.
- The sidecar runs `~/fm-mcp/mcp/dist`; restart the pod's `fm-mcp` container
  (or the pod) to pick up a new build.

## FM Bridge HTTP API (127.0.0.1:18765, inside the pod)

| Endpoint | Purpose |
|---|---|
| `GET /health` | main-thread pump, command channel, trace state |
| `GET /game/state` | save loaded, game date, FM's last-save record |
| `POST /game/load-last-save[?force=true]` | load FM's last save (main menu only) |
| `GET /schema/properties\|references\|contexts?q=` | FM's live identifier tables (~8.2k properties, ~930 record types) |
| `GET /enums/actions\|events` | `ActionID` / `InteropEventIDs` |
| `POST /read {paths, hold?, timeoutMs?}` | bind + read binding paths |
| `POST /write {path, value, hold?, timeoutMs?}` | set a binding value (FM pushes it where the engine accepts writes) |
| `POST /action/run {actionId, eventId, action, data, confirm}` | `PluginContextActionsModule.HandleActionEvent` |
| `POST /event/send {event, target?, data?}` | `GameInteropSubsystem.SendEvent` |
| `GET /bind/node?path=&depth=` | live binding-tree subtree |
| `POST\|GET\|DELETE /debug/trace` | opt-in trace of FM's command boundary (see below) |

## MCP tools

Read: `fm_status`, `fm_schema_search`, `fm_read`, `fm_read_list`, `fm_browse`,
`fm_search_players`, `fm_scan_records`, `fm_editor_fields`.
Write: `fm_edit_field`, `fm_run_action`, `fm_move_person`, `fm_send_event`,
`fm_write`, `fm_load_last_save`.

Verified on a copy of the career (2026-10-12): club balance and transfer budget
edits, stadium capacity, player CA, moving a player from another club,
terminating a contract, `TeamImproveTeamCohesion`, La Liga player search.

## How it works (FM26 internals the tools rely on)

- **Binding tree.** FM's UI reads a path-addressed tree (`SI.Bindable.Bindings`).
  Roots include `Human` (the manager), `game`, `app`, `config`; children are
  property names from the schema tables, and record-valued properties chain
  (`Human.Club.OverallBalance`). Nodes must be created by path
  (`Bindings.Create`) before binding; FM's interop data handler then opens
  native channels for them.
- **Spans.** Il2CppInterop passes `ReadOnlySpan<char>` as an empty span, so the
  plugin calls `Bindings.MakeKey`/`Create` through `il2cpp_runtime_invoke` with
  a hand-built span.
- **Records.** Every interop record is a list of `(id, value)` pairs, written as
  tokens `@id:value,…`. Database records are `@825307168:28,1198877028:<session>,1685218662:<table<<24|index>`;
  tables: 1 person, 3 club, 10 nation, 24 team, 25 competition. The session
  pair changes on every load.
- **In-Game Editor.** `<record>.Editor` → `Sections` → nested `Sections`/`Fields`
  → leaf fields with `PropertyValue`, `MinValue`, `MaxValue`, `IsReadOnly`.
  The engine serves values only while `<editor>.Sections` and each ancestor's
  `Sections`/`Fields` are bound, so reads and writes pass them as `hold`.
  Writing a leaf's `PropertyValue` applies the edit (no confirm event).
- **Actions.** Editor/context actions are `HandleActionEvent(ActionID, 44 =
  EventFmxDoAction, @825307168:1,1198877028:<session>,1633904996:<ActionID>,
  context)` where the context record carries `Human`, the target as
  `DatabaseReferenceField`, and the selection list.
- **Moves.** `EventFmxMoveToTeam` to
  `@825307168:57,1198877028:<session>,1348620377:<human>,1348825715:<person>,1769566810:<team>`
  moves the person without the editor dialog.

## Known limits

- String payloads built by the plugin (`TypedValue.Create<string>`, including
  inside records) crashed FM natively twice; `fm_edit_field` and
  `fm_send_event` accept numbers, booleans and record tokens only.
- Harmony hooks installed at plugin load deadlocked FM in
  `GAME_PLUGIN::initialise()`. The trace hooks install at runtime only
  (`POST /debug/trace {"enabled": true}` once the UI is up).
- Every plugin deploy restarts FM; unsaved progress is lost.
- `fm_search_players` reads every player of every scanned team (~1,000 per
  league, about a second); `fm_scan_records` on people is ~25 records/s.
- In-Game Editor writes and moves mark the save as edited, like the editor UI.
- FM must be running with a save loaded; otherwise tools return
  "FM Bridge unreachable" or "no save loaded".
