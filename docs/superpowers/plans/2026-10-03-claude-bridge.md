# Claude Subscription Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `claude-bridge` subscription bridge (pi-ai Anthropic core, house pattern) and wire it into Aether LiteLLM with pinned `claude/sonnet-5-5`, `claude/opus-5-5`, `claude/fable-5-1`.

**Architecture:** Sibling Bun/TS repo clones the grok-bridge operational skeleton (OpenBao KV v2 credentials, projected SA token, bridge bearer, hardened 1-replica deployment) but replaces the provider core: `@earendil-works/pi-ai` owns Anthropic OAuth (Claude Code client) and every upstream inference call through its typed streaming path; the bridge translates Anthropic Messages ↔ pi Context both directions. Aether adds `claude.tf`, a namespace contract, LiteLLM credential/model pins, the `claude:login` task, OMP/Colony allowlist entries, and docs.

**Tech Stack:** Bun 1.3.14, TypeScript 5.9 strict, `@earendil-works/pi-ai` 0.84.x, `bun:test`, OpenTofu, Kubernetes, LiteLLM, GitLab CI (Buildah).

**Spec:** `docs/superpowers/specs/2026-10-03-claude-bridge-design.md`

## Global Constraints

- pi-ai is a pinned exact dependency (`@earendil-works/pi-ai`); never fork, adapt, or deep-import paths outside its `exports` map (`.`, `./providers/*`, `./api/*`, `./oauth`, `./compat` are allowed).
- All upstream Anthropic traffic flows through pi-ai's stream path with the OAuth access token passed as `apiKey`; `maxRetries: 0`; the bridge never hand-builds Claude Code identity headers.
- Static model allowlist (exact upstream IDs): `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-fable-5-1`. No others, no passthrough of unknown IDs.
- Bridge bearer accepted as `Authorization: Bearer <key>` or `x-api-key: <key>` (timing-safe); everything else about caller auth matches grok-bridge.
- OpenBao KV v2 path `aether/claude-bridge/credentials`, k8s auth role `aether-k8s-claude-bridge`, CAS writes, single-flight refresh — identical semantics to grok-bridge.
- No PAYG/API-key fallback anywhere; no `/usage` endpoint; billing classification failure (third-party/extra-usage) fails closed.
- Names: repo `claude-bridge`, namespace `claude`, host `claude.home.shdr.ch`, env `CLAUDE_BRIDGE_API_KEY`, task `claude:login`, pins `claude/<short-name>`.
- Egress (in-cluster): DNS, `bao.home.shdr.ch`, `platform.claude.com`, `api.anthropic.com` only.
- Tests use `bun test` with injected `fetch` fakes; no test hits the network.

---

### Task 1: Scaffold the claude-bridge repository

**Files:**
- Create: `../claude-bridge/package.json`, `../claude-bridge/tsconfig.json`, `../claude-bridge/.gitignore`, `../claude-bridge/.dockerignore`, `../claude-bridge/THIRD_PARTY_NOTICES`

**Interfaces:**
- Produces: a typechecking Bun project with scripts `start`, `login`, `typecheck`, `test`, `check`; dependency `@earendil-works/pi-ai` installed at a pinned exact version.

- [ ] **Step 1: Create package.json** (mirror grok-bridge's, add pi-ai):

```json
{
  "name": "claude-bridge",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "bun run src/index.ts",
    "login": "bun run scripts/login.ts",
    "typecheck": "tsc --noEmit",
    "test": "bun test",
    "check": "bun run typecheck && bun test"
  },
  "dependencies": {
    "@earendil-works/pi-ai": "0.84.2"
  },
  "devDependencies": {
    "@types/bun": "1.3.14",
    "typescript": "5.9.3"
  }
}
```

(If `bun outdated` at execution time shows a newer pi-ai that still exports the same surface, pin that exact version instead; floor 0.84.2.)

- [ ] **Step 2: Copy `tsconfig.json`, `.gitignore`, `.dockerignore` verbatim from `../grok-bridge/`** (identical settings).
- [ ] **Step 3: Write THIRD_PARTY_NOTICES** crediting `@earendil-works/pi-ai` (MIT, earendil-works/pi) and its bundled `@anthropic-ai/sdk`.
- [ ] **Step 4: `bun install`** in `../claude-bridge`; verify `bunx tsc --noEmit` passes (empty project).
- [ ] **Step 5: `git init`, commit** `chore: scaffold claude-bridge`.

### Task 2: Provider-neutral utilities (clone from grok-bridge)

**Files:**
- Create: `../claude-bridge/src/safe-fetch.ts`, `../claude-bridge/src/bounded-json.ts`
- Test: `../claude-bridge/test/safe-fetch.test.ts` (copy of grok's)

**Interfaces:**
- Produces: `FetchLike`, `fetchNoRedirect`, `readBoundedText`, `readBoundedJson`, `parseBoundedJson` — identical signatures to grok-bridge.

- [ ] **Step 1:** Copy `src/safe-fetch.ts`, `src/bounded-json.ts`, `test/safe-fetch.test.ts` from `../grok-bridge/` byte-for-byte. Commit `feat: port bounded fetch utilities`.

### Task 3: Types, model allowlist, and metadata

**Files:**
- Create: `../claude-bridge/src/types.ts`, `../claude-bridge/src/models.ts`
- Test: `../claude-bridge/test/models.test.ts`

**Interfaces:**
- Produces: `ClaudeCredentials`, `VersionedCredentials`, `STATIC_MODEL_ALLOWLIST`, `bridgeModel(modelId): Model<"anthropic-messages">`, `intersectAllowedModels(liveIds: Set<string>): string[]`.

- [ ] **Step 1: `src/types.ts`:**

```ts
export interface ClaudeCredentials {
  schemaVersion: 1;
  access: string;
  refresh: string;
  expires: number;
  email: string | null;
  models: string[];
  billingVerifiedAt: number;
}

export interface VersionedCredentials {
  version: number;
  credentials: ClaudeCredentials;
}
```

- [ ] **Step 2: `src/models.ts`** — static allowlist + pi-ai Model construction (metadata from the omp catalog: 1M context, 128K output, thinking low→max, vision):

```ts
import type { Model } from "@earendil-works/pi-ai";

export const STATIC_MODEL_ALLOWLIST = [
  "claude-sonnet-5-5",
  "claude-opus-5-5",
  "claude-fable-5-1",
] as const;

export type AllowlistedModel = (typeof STATIC_MODEL_ALLOWLIST)[number];

const FREE_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

const MODEL_META: Record<AllowlistedModel, { name: string; effort: readonly string[] }> = {
  "claude-sonnet-5-5": { name: "Claude Sonnet 5.5", effort: ["low", "medium", "high", "xhigh", "max"] },
  "claude-opus-5-5": { name: "Claude Opus 5.5", effort: ["low", "medium", "high", "xhigh", "max"] },
  "claude-fable-5-1": { name: "Claude Fable 5.1", effort: ["low", "medium", "high", "xhigh", "max"] },
};

export function isAllowlisted(id: string): id is AllowlistedModel {
  return (STATIC_MODEL_ALLOWLIST as readonly string[]).includes(id);
}

export function bridgeModel(id: AllowlistedModel): Model<"anthropic-messages"> {
  return {
    id,
    name: MODEL_META[id].name,
    api: "anthropic-messages",
    provider: "anthropic",
    baseUrl: "https://api.anthropic.com",
    reasoning: true,
    thinkingLevelMap: { low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max" },
    input: ["text", "image"],
    cost: FREE_COST,
    contextWindow: 1_000_000,
    maxTokens: 128_000,
  };
}

export function intersectAllowedModels(liveIds: ReadonlySet<string>): AllowlistedModel[] {
  return STATIC_MODEL_ALLOWLIST.filter((id) => liveIds.has(id));
}
```

(At implementation, verify the `thinkingLevelMap` value type and `Model` compat requirements against the installed `.d.ts` and adjust to compile.)

- [ ] **Step 3: tests** — allowlist intersection, unknown-ID rejection, bridgeModel field sanity. Run `bun test`; commit `feat: model allowlist and metadata`.

### Task 4: OpenBao store

**Files:**
- Create: `../claude-bridge/src/bao.ts`
- Test: `../claude-bridge/test/bao.test.ts`

**Interfaces:**
- Produces: `TokenProvider`, `StaticTokenProvider`, `KubernetesTokenProvider`, `BaoCredentialStore` (read/write with CAS), `BaoError`, `BaoCasConflictError` — identical to grok-bridge except `parseCredentials` validates `ClaudeCredentials` (schemaVersion 1; `access`, `refresh` non-empty strings; `expires` finite; `email` string|null; `models` array of allowlisted IDs; `billingVerifiedAt` finite positive).

- [ ] **Step 1:** Copy `../grok-bridge/src/bao.ts` and replace only the import of types and `parseCredentials` body to validate `ClaudeCredentials`. Copy `test/bao.test.ts` and adapt the credential fixtures to the Claude shape.
- [ ] **Step 2:** `bun test test/bao.test.ts`; commit `feat: OpenBao credential store`.

### Task 5: pi-ai seam (OAuth client, inference, billing classification)

**Files:**
- Create: `../claude-bridge/src/pi.ts`
- Test: `../claude-bridge/test/pi.test.ts`

**Interfaces:**
- Consumes: `anthropicProvider()` from `@earendil-works/pi-ai/providers/anthropic`; `stream` from `@earendil-works/pi-ai/api/anthropic-messages`; `Context`, `AnthropicOptions`, `AssistantMessageEventStream` from the package root.
- Produces:
  - `anthropicOAuth: OAuthAuth` — obtained once via `anthropicProvider().auth.oauth` (throw if absent).
  - `interface OAuthLoginView { access: string; refresh: string; expires: number; extras: Record<string, unknown> }`
  - `runOAuthLogin(emit: (url: string) => void, prompt: (message: string) => Promise<string>, signal: AbortSignal): Promise<OAuthLoginView>` — drives `anthropicOAuth.login({ prompt, notify, signal })`, surfacing `auth_url` events to `emit`, refusing non-localhost URLs.
  - `refreshOAuth(credential: OAuthLoginView, signal?: AbortSignal): Promise<OAuthLoginView>` — `anthropicOAuth.refresh(...)`.
  - `streamClaude(modelId, context: Context, options: AnthropicOptions): AssistantMessageEventStream` — builds `bridgeModel(modelId)`, forces `maxRetries: 0`, passes options through.
  - `class UpstreamAnthropicError extends Error { constructor(readonly status: number, readonly body: unknown) }`
  - `classifyBilling(body: unknown): "extra-usage" | "forbidden" | "unauthorized" | undefined` — matches Anthropic error payloads: `error.type === "invalid_request_error"` with message containing `extra usage`/`Third-party apps` → `"extra-usage"`; `authentication_error` → `"unauthorized"`; `permission_error`/`forbidden` → `"forbidden"`.

- [ ] **Step 1: Write failing tests** for `classifyBilling` (all four branches + undefined), `streamClaude` forcing `maxRetries: 0` (assert via a spy fetch capturing the SDK call or via options identity through a fake stream), and `runOAuthLogin` refusing a non-localhost auth URL.
- [ ] **Step 2: Implement `src/pi.ts`.** Verify against the installed `.d.ts`: `OAuthAuth.login` interaction is `{ prompt, notify, signal }`; `notify` receives `{ type: "auth_url", url }` events; the credential returned is `{ type: "oauth", access, refresh, expires, ...extras }`. Map `AnthropicError` statuses from the stream's error events (an `AssistantMessage` with `stopReason: "error"` carries `errorMessage`; upstream HTTP status arrives through `onResponse` — attach `onResponse` in `streamClaude` to capture `response.status` into the stream's abort/error path). Adjust exactly as the real types require; keep the exported surface above stable.
- [ ] **Step 3:** `bun test test/pi.test.ts`; commit `feat: pi-ai OAuth and stream seam`.

### Task 6: Anthropic Messages ↔ pi adapters

**Files:**
- Create: `../claude-bridge/src/anthropic-request.ts`, `../claude-bridge/src/anthropic-events.ts`
- Test: `../claude-bridge/test/anthropic-request.test.ts`, `../claude-bridge/test/anthropic-events.test.ts`

**Interfaces:**
- Consumes: `Context`, `AnthropicOptions`, `AssistantMessageEvent` from pi-ai root; `AllowlistedModel` from `./models`.
- Produces:
  - `class AnthropicRequestError extends Error { constructor(message: string, readonly status = 400) }`
  - `toPiRequest(model: AllowlistedModel, body: Record<string, unknown>): { context: Context; options: AnthropicOptions; stream: boolean }`
  - `toAnthropicSse(model: string, events: AsyncIterable<AssistantMessageEvent>, signal: AbortSignal): ReadableStream<Uint8Array>` — emits `message_start`, `content_block_*`, `message_delta` (usage/stop_reason), `message_stop`.
  - `toAnthropicResponse(model: string, events: AsyncIterable<AssistantMessageEvent>): Promise<Record<string, unknown>>` — aggregates to a single Messages response.
- Mapping rules (all rejections throw `AnthropicRequestError` → HTTP 400):
  - `system`: string → `systemPrompt`; array of `{type:"text",text}` blocks → joined; anything else → 400.
  - `messages`: `user` with string or `{type:"text"}`/`{type:"image"}` (base64 `source` with `type:"base64"`) content → pi `UserMessage`; `assistant` content blocks `text`→TextContent, `thinking` (+`signature`→thinkingSignature) →ThinkingContent, `tool_use`→ToolCall (`input`→arguments) — synthesized `AssistantMessage` fields (`api: "anthropic-messages"`, `provider: "anthropic"`, `model`, zero `usage`, `stopReason` from `stop_reason`, `timestamp: 0`); `tool_result` blocks → separate `ToolResultMessage` (`content` text/image blocks, `is_error`→isError) ordered directly after the assistant message that produced them.
  - `tools` → pi `Tool` (`input_schema`→parameters); `tool_choice` → `options.toolChoice` (`{type:"tool",name}` passes name; `auto`/`any`/`none` verbatim; else 400).
  - `max_tokens`→`options.maxTokens`; `temperature`→`options.temperature`; `top_p`/`top_k`→`options.samplingParams` (verify passthrough in pi's compiled `anthropic-messages.js`; if pi drops them, reject with 400 and document); `stop_sequences`: verify pi support in the compiled transform — map if supported, else 400 with a clear message.
  - `thinking: {type:"enabled", budget_tokens}` → `thinkingEnabled: true, thinkingBudgetTokens`; `stream` → boolean.
  - Unknown top-level fields → 400 (never silently dropped).
- Event mapping: `text_*`→`content_block_*` with `text_delta`; `thinking_*`→`content_block_*` with `thinking_delta`; `toolcall_*`→`content_block_*` with `input_json_delta` (serialize argument deltas); `done`→`message_delta` (stop_reason: toolUse→`tool_use`, length→`max_tokens`, stop→`end_turn`) + `message_stop`; usage from the final message (`message_delta.usage` with input/output tokens). An `error` event mid-stream emits an Anthropic `error` SSE event and stops — never a synthetic successful finish.
- [ ] **Step 1:** Write failing tests for each mapping rule above (round-trip: sample Anthropic request → captured pi context/options; sample event sequence → expected SSE bytes; aggregation for non-streaming; every rejection case). Use fixture JSON drawn from Anthropic Messages docs shapes.
- [ ] **Step 2:** Implement both adapters. Run both test files. Commit `feat: Anthropic Messages adapters`.

### Task 7: Credential manager

**Files:**
- Create: `../claude-bridge/src/credentials.ts`
- Test: `../claude-bridge/test/credentials.test.ts`

**Interfaces:**
- Consumes: `CredentialStore` (as in grok-bridge), `refreshOAuth`/`OAuthLoginView` from `./pi`.
- Produces: `ClaudeCredentialManager` with the exact grok-bridge lifecycle minus metadata/privacy: `initialize`, `ready()` (credential loaded + `models` non-empty + `billingVerifiedAt` set), `markInvalid()`, `accessToken(signal)`, `refreshAfterUnauthorized(failedToken, signal)`, `markBillingFailure()` (sets invalid; remedy is re-login or pi-ai update), `credentials()`. Single-flight refresh; CAS-conflict adoption identical to grok-bridge.
- [ ] **Step 1:** Copy grok's `credentials.ts` structure; strip `MetadataLoader`/privacy; add `billingVerifiedAt` gate and `markBillingFailure`. Adapt tests (copy `credentials.test.ts`, replace metadata scenarios with billing scenarios). Run. Commit `feat: credential manager`.

### Task 8: Server and entrypoint

**Files:**
- Create: `../claude-bridge/src/server.ts`, `../claude-bridge/src/index.ts`
- Test: `../claude-bridge/test/server.test.ts`

**Interfaces:**
- Consumes: everything above.
- Produces: `createBridgeHandler(options)` and the runtime wiring (env: `BAO_ADDR`, `BRIDGE_API_KEY`, `BAO_AUTH_PATH=kubernetes-aether`, `BAO_ROLE=aether-k8s-claude-bridge`, `BAO_KV_MOUNT=kv`, `BAO_SECRET_PATH=aether/claude-bridge/credentials`, `BAO_JWT_PATH`, `PORT=8080`).

Routes: `GET /health`, `GET /ready` (same semantics as grok; ready = manager.ready()), `GET /v1/models` (Anthropic-format `{data:[{id, display_name, created_at, type:"model"}]}`, allowlist ∩ persisted live catalog), `POST /v1/messages` (the only inference route; everything else 404).
Behavior deltas from grok's server: auth accepts `Authorization: Bearer` or `x-api-key`; body → `toPiRequest` (400 on `AnthropicRequestError`); execute via `streamClaude` with `signal` = client ∪ idle-timeout; SSE via `toAnthropicSse`, non-stream via `toAnthropicResponse`; upstream 401 → one `refreshAfterUnauthorized` + retry; 403 → `revalidate` (manager invalid; fail closed); response body matching `classifyBilling === "extra-usage"` → `markBillingFailure` + 503 with sanitized message; 429 preserves status + `retry-after`; other 4xx pass through; network/5xx → 502 upstream-unavailable. 16 MiB body bound; SSE idle timeout 900 s (connection + per-read), `idleTimeout: 0` on `Bun.serve`; structured request logs (request_id, model, bytes, upstream_status, total_ms, aborted) with no prompt/response content.
- [ ] **Step 1:** Write failing server tests (port grok's `server.test.ts` structure): route auth matrix, both header forms, models endpoint shape, messages 400 mapping, 401-refresh-retry-once, extra-usage fail-closed, 429 passthrough, SSE relay end-to-end with fake pi stream, client cancellation.
- [ ] **Step 2:** Implement server + index. Run full `bun run check`. Commit `feat: bridge server`.

### Task 9: Login script

**Files:**
- Create: `../claude-bridge/scripts/login.ts`
- Test: `../claude-bridge/test/login.test.ts`

**Interfaces:**
- Consumes: `runOAuthLogin`, `streamClaude`, `BaoCredentialStore` + `StaticTokenProvider`, `intersectAllowedModels`, live catalog fetch.
- Produces: `runLogin(deps)` as in grok's login (injectable deps; `import.meta.main` wiring with `VAULT_ADDR`, `VAULT_TOKEN`, `CLAUDE_BAO_MOUNT=kv`, `CLAUDE_BAO_PATH=aether/claude-bridge/credentials`).

Flow: read existing version (404 → 0) → `runOAuthLogin` (print URL; prompt fallback reads stdin) → live model catalog: GET `https://api.anthropic.com/v1/models` with the OAuth token via a pi-ai stream-consistent client — use pi-ai's exported provider plumbing where possible; otherwise a plain Bearer GET is acceptable for the read-only catalog because it carries no identity claims (document this exception in README; inference still pi-ai-only) → intersect allowlist, require ≥1 → billing marker: one-token `streamClaude("claude-fable-5-1" or first available, {messages:[{role:"user",content:"ok"}], maxTokens 16})`; if the response error classifies as extra-usage → abort without persisting → write record with CAS → log success only.
- [ ] **Step 1:** Failing tests: abort-on-extra-usage, no-model abort, happy path writes CAS record with `billingVerifiedAt`.
- [ ] **Step 2:** Implement. `bun run check`. Commit `feat: workstation login`.

### Task 10: Image, CI, README

**Files:**
- Create: `../claude-bridge/Dockerfile`, `../claude-bridge/.gitlab-ci.yml`, `../claude-bridge/README.md`

- [ ] **Step 1:** Copy `Dockerfile` and `.gitlab-ci.yml` from grok-bridge verbatim (same digest-pinned Bun and Buildah images; `bun.lock` is included by the build). Write README mirroring grok's: routes, env, no-PAYG/no-usage stance, pi-ai identity policy, billing invariant, catalog-fetch exception note, local dev.
- [ ] **Step 2:** `bun run check` once more; commit `chore: image, ci, docs`. Tag `v1.0.0` and attempt `git push` to `ssh://git@ssh.gitlab.home.shdr.ch:2222/so/claude-bridge.git` (create project via push-to-create if enabled; otherwise record as an operator step).

### Task 11: Aether deployment declarations

**Files:**
- Create: `tofu/home/kubernetes/claude.tf`
- Modify: `tofu/home/kubernetes/namespace_contracts.tf` (add `claude` stanza beside grok's at ~1006–1021, host `claude.home.shdr.ch`, source file `claude.tf`, health probe path entry beside the muse/grok entries at ~1323–1325)

**Interfaces:**
- Consumes: grok.tf as the exact template (same resources: locals+`random_password.claude_bridge_api_key`, SA, Bao policy path `aether/claude-bridge/credentials`, k8s auth role `aether-k8s-claude-bridge`, GitLab pull secret, caller-key Secret, hardened 1-replica Recreate Deployment with projected Bao token, Service, HTTPRoute, CiliumNetworkPolicy).
- Produces: deployment keyed on `claude-bridge` image digest.

- [ ] **Step 1:** Write `claude.tf` as a find-replace adaptation of `grok.tf` (grok→claude names, host, bao path, role, egress FQDNs `bao.home.shdr.ch`/`platform.claude.com`/`api.anthropic.com`, health path `/health`). The image digest is `<gitlab-registry>/so/claude-bridge@sha256:<digest>` — fill from CI after Task 10's push; until then leave `claude.tf` uncommitted and track the digest as the gating value.
- [ ] **Step 2:** Add the namespace contract stanza + probe path. `tofu fmt`, `tofu validate` (needs the digest only at apply time). Commit `feat: claude bridge workload` once the digest is real.

### Task 12: LiteLLM integration

**Files:**
- Modify: `tofu/home/kubernetes/litellm.tf` (add `CLAUDE_BRIDGE_API_KEY` to the `litellm-env` Secret map from `random_password.claude_bridge_api_key.result` beside the muse/grok entries ~:70–72, and the container `secretKeyRef` beside ~:366–385)
- Modify: `tofu/home/kubernetes/litellm_config.yaml.tftpl` (credential block beside grok's at ~:772–777; three model entries beside the SuperGrok pin shape ~:699–724)
- Modify: `Taskfile.yml` (`claude:login` beside `grok:login` ~:277–284, `CLAUDE_BRIDGE_REPO:-../claude-bridge`)
- Modify: `ansible/playbooks/register_litellm_virtual_keys.yml` (add the three pins to the `omp` and `colony` alias lists; nothing else)

**Interfaces:**
- Produces: `claude_bridge_credential` + pins:

```yaml
- credential_name: claude_bridge_credential
  credential_values:
    api_base: https://claude.home.shdr.ch/v1
    api_key: os.environ/CLAUDE_BRIDGE_API_KEY
  credential_info:
    description: "Claude subscription via pi-ai backed single-tenant bridge"
```

and per model (sonnet-5-5 shown; opus-5-5/fable-5-1 identical apart from names/ids):

```yaml
- model_name: claude/sonnet-5-5
  litellm_params:
    model: anthropic/claude-sonnet-5-5
    credential_name: claude_bridge_credential
    use_chat_completions_api: true
    cooldown_time: 0
    timeout: 900
    stream_timeout: 900
    allowed_openai_params: [reasoning_effort]
```

(`model_info` metadata: mode chat, 1 000 000 context, 128 000 output, vision + tools + reasoning true — mirror the SuperGrok entry's fields.)

- [ ] **Step 1:** Apply the four file modifications. Run: `nix develop --command bash -c 'tofu fmt -check && tofu validate'` in `tofu/home`, `task --list` parse, `ansible-playbook --syntax-check`, and a YAML parse of the rendered litellm template (render via the same templatevars path `task tofu:plan` uses, or verify by eyeball + `yq` on a manual render).
- [ ] **Step 2:** Targeted `task tofu:plan`; require zero destroys and only additive changes. Commit `feat: expose pinned Claude models`.

### Task 13: Documentation

**Files:**
- Modify: `docs/ai-ml.md` (new Claude section beside SuperGrok's, and provider inventory table row)

- [ ] **Step 1:** Document: bridge ownership split, pi-ai dependency policy, credential path + `task claude:login`, billing invariant + fail-closed behavior, pins, egress, no-PAYG/no-usage, LiteLLM translation boundary, troubleshooting (extra-usage error → update pi-ai; 401 loop → re-login). Commit `docs: document Claude bridge`.

### Task 14: Operator-gated rollout (requires the user)

Not executable autonomously; run when the operator returns:

- [ ] Push `claude-bridge` if Task 10 couldn't; confirm GitLab CI green; capture the `sha256:` digest into `claude.tf`; commit.
- [ ] `task tofu:apply` (claude namespace/workload + litellm secret/env/config).
- [ ] `task claude:login` — browser OAuth at claude.ai; confirm billing marker passes; verify Bao record exists (`bao kv get kv/aether/claude-bridge/credentials` metadata only).
- [ ] Rollout ready; `curl https://claude.home.shdr.ch/ready` green.
- [ ] Direct bridge streaming marker: `POST /v1/messages` with `claude-sonnet-5-5` (thinking + one tool) through LiteLLM's `claude/sonnet-5-5` Chat Completions; assert marker, tool calls, thinking, usage.
- [ ] `task configure:litellm-keys`; confirm OMP + Colony can select the three pins; defaults unchanged.
- [ ] Verify egress (Cilium) blocks anything beyond the four destinations; no `x-api-key` auth upstream (Bearer only).
