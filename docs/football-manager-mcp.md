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
- The sidecar runs `~/fm-mcp/mcp/dist`. Pick up a new build without touching
  FM with `kubectl -n games exec <pod> -c fm-mcp -- kill 1` (the server exits on
  SIGTERM and the kubelet restarts the container; repeated restarts hit
  CrashLoopBackOff delays of up to minutes). `noEmitOnError` keeps a failed
  build from replacing `dist`.

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
`fm_search_players`, `fm_scan_records`, `fm_editor_fields`,
`fm_responsibilities`, `fm_tactic`, `fm_inbox`, `fm_inbox_message`,
`fm_match`, `fm_results`, `fm_fixtures`, `fm_league_table`,
`fm_team_snapshot`, `fm_rivals`.
Write: `fm_edit_fields`, `fm_run_action`, `fm_move_person`,
`fm_set_responsibilities`, `fm_set_tactic`, `fm_set_roles`, `fm_set_instructions`,
`fm_pick_players`, `fm_inbox_mark_read`, `fm_send_event`,
`fm_write`, `fm_load_last_save`.

Verified on a copy of the career (2026-10-12): club balance and transfer budget
edits, stadium capacity, player CA, moving a player from another club,
terminating a contract, `TeamImproveTeamCohesion`, La Liga player search,
staff attribute/CA edits across editor tabs, responsibility reassignment and
taking control, tactic slot/style/mentality changes, in- and out-of-possession
role changes (including 2^56 role flags), multi-step team instruction changes
and their restore, picking and moving players in the XI.

Verified live (2026-10-15): inbox listing/filters/triage and mark-read,
Valencia's completed results with scorers and assists, upcoming fixtures, the
derived league table (matches FM's `LeaguePosition` for all 20 teams) and
rival snapshots.

Not covered yet: player instructions (see below), set-piece routines,
opposition instructions, live in-match state (`fm_match` falls back to the last
completed match; no live-only fixture property resolved outside a match).

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
  `EventFmxRefreshIgeProperties` to the editor token selects the editor tab
  (its payload is the tab index; staff: 0 Details, 2 Attributes/General/Staff
  Roles, 4 Club Contract). Section numbers are global across tabs, so
  `fm_editor_fields` walks tabs 0–7 and returns `{tab, field}` per field.
- **Editor tables.** Some editor groups are tables: the group field has
  `Columns` (`…,2:<c>`) and `Rows` (`…,2:-<r>`, labelled by `RowString`), and
  each row's `Fields` are cells (`…,2:-<r>,3:<c>`) that edit like any field.
  Club `Finances › Other Income` (`0:5,1:1`) is the sponsorship/commercial
  income table: Total Value (cash, ±1,000,000,000 per row), Income Type, Start/End
  Date, Renew Income, Fixed Value. `SponsorshipsData` on the club is a
  read-only view of it. FM re-sorts rows when a value changes, so
  `fm_edit_fields` re-finds each row by its label and cell values before
  writing. `Finances › Debt and Loans` (`0:5,1:3`) lists loans (Original Debt,
  Monthly Repayment, Monthly Interest Repayment, …); setting a loan's Original
  Debt to 0 makes FM delete that row, which clears the loan.
- **Staff data.** Staff attributes are direct person properties (`Attacking`,
  `Defending`, `Possession`, `SetPieces`, `Tactical`, `Technical`,
  `CoachingFitness`, `GoalkeepingCoaching`, `WorkingWithYoungster`,
  `Motivating`, `PeopleManagement`, `JudgingPlayerAbility`, `AnalysingData`,
  `Physiotherapy`, `SportsScience`, …); `StaffRoles` holds FM's 0–20 role
  suitability per job, `PreferredJob` / `PrimaryClubJobRecord` the jobs.
- **Actions.** Editor/context actions are `HandleActionEvent(ActionID, 44 =
  EventFmxDoAction, @825307168:1,1198877028:<session>,1633904996:<ActionID>,
  context)` where the context record carries `Human`, the target as
  `DatabaseReferenceField`, and the selection list.
- **Moves.** `EventFmxMoveToTeam` to
  `@825307168:57,1198877028:<session>,1348620377:<human>,1348825715:<person>,1769566810:<team>`
  moves the person without the editor dialog. A moved staff member gets their
  `PreferredJob` as `PrimaryJob` on the new contract.
- **Staff jobs.** `<move token>.JobOptions` lists the jobs a person can take
  (`{DisplayValue, PropertyValue:{1348692591: JobType, 1416914273: team}}`).
  `EventFmxMoveToTeamConfirm` to the move token with that `PropertyValue` as data
  hires straight into the job (writing `SelectedJob` does not survive). The
  team field renders empty but matters: Valencia B is its own club, and a
  "Valencia B …" job needs `1416914273: {DatabaseReferenceField: <B team>}`.
  Sent empty, it means the first team. A B-team Head Coach sent that way
  replaced the manager (2026-10-12), so check the hiring club and the
  manager's job after every hire. Doctors have no `JobOptions`, so they can't be
  hired this way. Staff Recommended CA follows the job's attributes but is
  capped by PA. The first team has a single Assistant Coach seat: a second
  first-team assistant replaces the first. The U19 assistant ("Under 19s
  Assistant Coach", team field = U19 team) also reads back as "Assistant Coach".
- **Responsibilities.** `Human.Club.TeamSettingsEditSession` is a
  `TeamSettingsEditSessionReference` (`@825307168:115,…,<human>,<club>`):
  `ResponsibilityTabList` → tab (124) `ResponsibilityGroupList` → group (122)
  `ResponsibilityList` → responsibility (120) with `ResponsibilityName`,
  `StaffMemberInCharge`, `AssignableStaffList`, `IsUserInControl`. Writing
  `StaffMemberInCharge` (a person token; the manager = take control) and sending
  `EventFmxConfirmTeamSettings` to the session commits it. The session is a
  snapshot: after staff changes it keeps departed staff assignable until it is
  rebuilt, either by opening Staff › Responsibilities or by sending
  `EventFmxConfirmTeamSettings` with no pending edits.
- **Tactics.** `@825307168:126,<session>,1651271022:1,1685218662:<team>` is the
  team's `TeamTacticReference`. `CurrentTacticSlot`, `TacticalStyle` and
  `Mentality` are directly writable (a style change resets mentality).
  `TacticalPositionsCombined` lists positions with `IPRole`/`OOPRole` flags
  (`FM.UI.InPossessionRole` / `OutOfPossessionRole`, powers of two up to 2^57).
  `EventFmxSelectRole` to the tactic with
  `{TeamSelectionIndex, Role:{PropertyValue, DisplayValue:{Role:<flag>}}, IsInPossession}`
  sets a role; FM ignores roles a position can't take, and drops events sent
  within a frame or two of the previous one (`fm_set_roles` paces and
  retries). Position flags: lower bit = right (D 4/8/16, WB 32/64, DM 128,
  M 256/512/1024, AM 2048/4096/8192, ST 16384); a shared central slot carries
  2097152 = centre-right or 1048576 = centre-left. Flags above 2^53 must be
  sent as exact integer literals (the plugin parses Int64 digits verbatim).
- **Team instructions.** 28 instructions are tactic properties (`Tempo`,
  `DefensiveLine`, `PressingTrigger`, `BuildUpStrategy`, …) whose value is the
  schema property id of the selected option's name (`HigherTempo`,
  `PlayThroughPress`, …). `EventFmxQuickChangeTacticInstructionIncrement` /
  `Decrement` to the tactic with the instruction index as data steps one
  option; the index → instruction map and option order are in `tactics.ts`.
  Steps sent within a frame or two of the previous one are dropped, so the tool
  settles 200 ms per step and resends unconfirmed steps. The options panel's
  `SelectedTeamInstructionOption` write only resolves inside the panel's
  binding context.
- **Starting XI.** `EventFmxTeamSelectionPickPlayer` to the tactic with
  `{PropertyValue: 2, DisplayValue:{Player, PlayerTeamSelectionIndex, Index, TeamSelectionIndex}}`
  (`Index` = the person's database index, `PlayerTeamSelectionIndex` = their
  current slot or -1) places a player. The engine accepts anyone, even another
  club's staff, so `fm_pick_players` restricts picks to `<team>.Players`.
- **Player instructions.** The UI steps them with
  `EventFmxQuickChangePlayerInstructionIncrement` / `Decrement` to the tactic
  with `{TeamSelectionIndex, PlayerInstructionGroupID, IsInPossession}`. Their
  current values (`SelectedPlayerInstruction`, `PlayerInstructionGroupOptions`)
  are served by `PlayerInstructionGroupDataHandler` /
  `PlayerInstructionEntryDataHandler` only with binding contexts the panel's
  `BindingRemapper` supplies (TeamSelectionIndex, PlayerInstructionGroupID,
  InPossession). `@910447949:0` is not a UI record, and stepping events sent
  without the panel open leave `PlayerPersonalisedInstructionsCountText` at
  "0 players set". Supporting them needs a plugin endpoint that reads and
  writes with explicit contexts.
- **Inbox.** The portal list properties never resolve through the bridge;
  `fm_inbox` anchors on `HumanPortalOldestUnreadMessage` /
  `HumanPortalLastSelectedMessageReference` and scans message ids (kind 70)
  around them. Mark-read is `EventFmxMarkPortalMessageAsRead` to the message.
- **Fixtures and the table.** `LeagueTable` / standings properties do not
  resolve. Fixture tokens (kind 50) are built per team pairing and date (the
  packed date advances 256 per day), filtered by `Competition` and a
  non-negative score; the table is derived with FM's head-to-head tie-break.
  The true home side comes from stadium ownership.
- **Advancing time.** The Continue button sends `EventFmxContinueGame` with
  target `@825307168:54`; without that target the event is ignored. A forced
  news screen is dismissed with `EventFmxRemoveNewsAggregatorForcedScreen` to
  the human person. Each continue may advance only part of a day; poll
  `game.GameProcessing` and `game.GameManagersNotContinuedCount`, not the date.
  `EventFmxSaveGame` with the same target saves to the loaded save file.
- **Preferred squad number.** Editor tab 0 field `0:0,1:28` is optional; write
  `IsOptionalFieldTicked=false` to blank it. The actual squad number is not
  changed by this field.

## Known limits

- String payloads built by the plugin (`TypedValue.Create<string>`, including
  inside records) crashed FM natively twice; `fm_edit_fields` and
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
