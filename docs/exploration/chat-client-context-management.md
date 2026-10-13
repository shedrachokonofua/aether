# Chat-client context management: OpenWebUI vs agent engines

Read from source on 2026-10-13 to decide whether to keep OpenWebUI or build an
own UI on an agent engine. Prompted by one OpenWebUI chat that re-sent ~500k
tokens (827 messages, 57 tools) to Muse Wonder Full on every tool round.
`path:line` citations are at the commit listed per client.

| Client | Commit |
|---|---|
| OpenWebUI | `v0.12.0` (`15818d8`) |
| omp (oh-my-pi) | `818dd42` |
| Codex CLI | `f82e365` |
| jcode | `0d240f1` |
| Hermes Agent | `v2026.9.24` (`f97608f`) |
| LibreChat | `e1dfc10` |
| LobeHub | `7243406` |

## Context handling

| | Compaction default / trigger | Between tool rounds | Tool-output cap | Old tool results | Cache hints | Server-side state |
|---|---|---|---|---|---|---|
| **OpenWebUI** | **off**; fixed 80k tokens, chars/4 estimate, tool schemas uncounted | yes, if enabled | **none** | replayed in full | none automatic | opt-in, one tool loop only |
| omp | on, ~85% of effective window | yes | spills >50 KiB to artifacts | cache-aware pruning | `cache_control`, `prompt_cache_key` | `previous_response_id` on OpenAI Responses |
| Codex | on, 90% of window (244.8k on bundled Sol) | yes | exec output 10k tokens | dropped at compaction (lossy) | stable prefix | WebSocket deltas via `previous_response_id`; HTTP full, `store=false` |
| jcode | on, 80% of window; OpenAI native at 200k | yes | guards per tool, screenshots decay | 10 recent records kept | yes | WebSocket `previous_response_id` deltas |
| Hermes | on, min(50% of window, 256k) ≈ 231k on Codex OAuth | yes | 100k/result spilled, 1.5k preview | lean tail kept | content-hashed `prompt_cache_key` | stateless, `store:false` |
| LibreChat | on, model-aware budget, same model | yes | model-relative, ≤400k chars | age pruning off | Anthropic caching on | full history |
| LobeHub | on, 50% / 65% of window | yes | 25k chars, archived | cache-aware trimming | Anthropic breakpoints, OpenAI cache keys | full input, `store:false` |

OpenWebUI is the only client whose safety features are all off by default:
- `ENABLE_CONTEXT_COMPACTION=False` (`backend/open_webui/config.py:2212`).
- `ENABLE_TOOL_SEARCH=False` (`config.py:2227`).
- No fit to the model's context window: compaction returns the list unchanged when disabled (`utils/context_compaction.py:54`), and overflow is left to the provider (`utils/middleware.py:6375`).
- No generic tool-result cap; results are stored and replayed in full (`middleware.py:1295`, `:6128`; `utils/misc.py:434`).

Its compaction, once enabled, is reasonable: it keeps tool-call and result batches intact (`context_compaction.py:335`) and can run between tool rounds (`middleware.py:6299`).

## Code structure

| | Size | Largest unit | Tests run per PR |
|---|---|---|---|
| **OpenWebUI** | 117k Python LOC backend | `streaming_chat_response_handler`: **one 2,317-line function** (`middleware.py:4456`), wrapping a 2,192-line `response_handler` and a 947-line `stream_body_handler`; `process_chat_payload` 993 lines; `Chat.svelte` 5,287 lines | formatting plus `ruff --select=F`; the 910-file suite lives in `open-webui/tests` and gates release PRs only (`.github/workflows/regression.yaml`) |
| omp | ~1.0M TS LOC | `session/agent-session.ts` 13,738 lines | 3,155 test files in-tree |
| Codex | ~2.05M Rust LOC | largest files are tests | ~2,400 test modules/files |
| LibreChat | ~760k LOC | `GenerationJobManager.ts` 9,785 lines | 2,389 test files |
| LobeHub | ~1.6M LOC | `models/message.ts` 5,843 lines | 4,377 test files |

Size alone does not separate them: every codebase has multi-thousand-line files. OpenWebUI differs in three ways:
- **Its whole chat and tool pipeline is concentrated in a few giant functions.** History building, the tool loop, compaction, RAG and persistence all live there.
- **Its per-PR checks never exercise that pipeline.**
- **Its unsafe defaults.**

The repeated tool-history bugs fit that picture: dropped calls (#28305), orphaned results (#28570), results saved under the wrong call (#28937), invalid arguments breaking the chat (#31960), and calls sent twice after `ask_user` (#31991, fixed in 0.12.0).

## Engines a custom UI could drive

- **omp:** `--mode rpc` / `rpc-ui` (`packages/coding-agent/src/main.ts:272`) plus an SDK that passes `sessionId` and `promptCacheKey`. Compaction and pruning are on by default and run between tool rounds. Weakness: on stateless transports it still re-sends every active message between compactions.
- **Codex:** the `app-server` JSON-RPC protocol (`codex-rs/app-server*`), which its editor and desktop apps use, is the best reference for a UI-to-engine boundary. Weakness: compaction is lossy, dropping assistant and tool history for an opaque server summary.
- **Hermes:** worth borrowing:
  - a separate summarizer model;
  - tool results spilled to disk, leaving only a preview in the conversation;
  - small, frozen memory, with skills listed as a 60-character index;
  - a content-hashed `prompt_cache_key`.

## Usage that a move would have to cover (OpenWebUI DB, 2026-10-13)

- **Accounts:** 7 (1 admin, 6 users); 2 active in the last 30 days (admin 41 chats, users 2).
- **Data:** 232 files, 50 notes, 24 calendar events, 4 memories, 1 channel.
- **Not used:** no knowledge bases, tools or functions.
- **Configured:**
  - Keycloak OIDC with role mapping;
  - speech-to-text and text-to-speech;
  - the Jupyter code interpreter and Open Terminal;
  - web search and hybrid RAG;
  - sub-agents.
