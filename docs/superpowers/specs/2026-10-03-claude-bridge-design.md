# Claude Subscription Bridge Design

## Status

Approved architecture for implementation. The bridge is private, single-tenant infrastructure behind Aether LiteLLM. It is not a public or multi-account Anthropic gateway.

## Goal

Expose the operator's Claude Pro/Max subscription to Aether clients through pinned `claude/*` LiteLLM model names while keeping OAuth credentials server-side. Expose the latest subscription models — Sonnet, Opus, and Fable — through Anthropic's native Messages API. There is no PAYG fallback and no Anthropic Console API-key path.

The bridge's Anthropic connection machinery is the `@earendil-works/pi-ai` package (the pi project's Anthropic provider): its OAuth login and refresh, and its Claude Code client identity on every inference request. The bridge never re-implements that identity layer.

## Source and compatibility basis

The connection core is the MIT-licensed `@earendil-works/pi-ai` npm package from the `earendil-works/pi` repository (badlogic's pi-mono), consumed as a pinned library dependency — not adapted or forked code.

pi-ai provides, and the bridge relies on:

- `loginAnthropic()`: PKCE authorization-code OAuth against `https://claude.ai/oauth/authorize` and `https://platform.claude.com/v1/oauth/token`, using Claude Code's official public client ID, a localhost callback server, and the fixed scope set `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`.
- `refreshAnthropicToken()`: refresh-token rotation for expiring access tokens.
- The Anthropic Messages request path (`api.anthropic.com/v1/messages`) with the current Claude Code client identity: `Authorization: Bearer`, `user-agent: claude-cli/<tracked Claude Code version>`, `x-app: cli`, `anthropic-beta: claude-code-20250219,oauth-2025-04-20,…`, the Claude Code system-prompt prefix, and Claude Code tool naming (tracked against badlogic's `cchistory`).

Version policy: pin an exact pi-ai version whose OAuth and identity layer is current at implementation time (floor 0.84.2, the version antigravity-bridge runs). pi-ai's bundled model catalog is known stale (it lacks the current Sonnet/Opus/Fable revisions); the bridge therefore supplies its own model metadata and must not depend on pi-ai's catalog for the pinned models. Claude Code identity churn is absorbed by dependency updates, never by bridge edits.

Billing context: since 2026-04-04 Anthropic routes *detected* third-party clients to per-token "extra usage" instead of plan limits. pi-ai matches the current Claude Code client so subscription traffic draws from plan limits. This is the same class of CLI-identity bridging Aether already runs for SuperGrok (pinned Grok CLI headers) and Muse (minted subscription key); it is not sanctioned by Anthropic and carries detection/ban risk. The bridge must fail visibly rather than serve silently billed traffic (see the billing invariant).

## Non-goals

- No PAYG Anthropic Console API-key support or fallback. No `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` acceptance.
- No account pooling or credential rotation between Anthropic accounts.
- No public or multi-tenant bridge.
- No OpenAI Chat Completions or Responses endpoints on the bridge. LiteLLM's `anthropic/` provider owns caller-side protocol translation at its boundary.
- No `/v1/messages/count_tokens`, batches, files, realtime, server-side tools (web search etc.), or arbitrary `/v1/*` forwarding.
- No `/usage` endpoint: Anthropic exposes no documented subscription-quota API. Rate-limit headers pass through on error responses only.
- No server-owned tool execution or agent loop.
- No prompt, response, raw account payload, or credential persistence in bridge logs.
- No mutation of the Anthropic account or its settings.

## Repository ownership

Create a dedicated private `claude-bridge` GitLab repository beside `muse-bridge`, `grok-bridge`, and `antigravity-bridge`.

The bridge repository owns:

- Bun/TypeScript source and behavior tests.
- The pi-ai dependency pin and its integration seam.
- Anthropic Messages ↔ pi-ai Context request/event adapters (both directions).
- Model allowlist and per-model metadata.
- OpenBao credential persistence.
- Workstation login script (OAuth + entitlement discovery + billing check).
- Container image, Dockerfile, and GitLab CI.
- Runtime interface documentation.

Aether owns:

- The Kubernetes namespace and workload resources.
- Internal Gateway/HTTPRoute and DNS name.
- OpenBao policy and Kubernetes authentication role.
- Bridge bearer generation and Kubernetes Secret.
- Immutable image digest pin.
- LiteLLM credential and pinned `claude/*` model entries.
- The OMP virtual-key allowlist.
- The workstation login task.

## Bridge interface

### `GET /health`

Unauthenticated process liveness. Returns success after process initialization even when credentials or upstream access are unavailable. It reveals no account, token, quota, or model information.

### `GET /ready`

Unauthenticated readiness. Returns success only when:

- OpenBao authentication succeeded.
- A structurally valid credential record was loaded.
- The OAuth credential is not expired beyond refreshability or definitively revoked.
- The live upstream model catalog (cached within a bounded TTL) intersects the static allowlist in at least one model.

Transient upstream failures do not permanently invalidate readiness. A definitive authorization failure or an upstream third-party/extra-usage classification does.

The response contains only coarse status fields.

### `GET /v1/models`

Requires the bridge bearer. Returns an Anthropic-format catalog containing only allowlisted model IDs that are present in the live account catalog. Newly discovered model IDs are never exposed until explicitly added to both the static allowlist in code and Aether's LiteLLM configuration.

Static allowlist at implementation (latest revisions, confirmed against the live catalog at bootstrap):

- `claude-sonnet-5-5`
- `claude-opus-5-5`
- `claude-fable-5-1`

### `POST /v1/messages`

Requires the bridge bearer (accepted as `Authorization: Bearer` or `x-api-key`; LiteLLM's anthropic provider sends the latter). This is the only inference endpoint.

The bridge:

1. Requires a bounded JSON request body.
2. Validates the requested model against the allowlisted live catalog (upstream IDs verbatim; no rewrite).
3. Converts the Anthropic Messages request to a pi-ai Context: messages (text, image, thinking, tool_use, tool_result blocks), system, tools, tool_choice, max_tokens, temperature, top_p, stop_sequences, and thinking budget. Unsupported or malformed controls fail with `400`; nothing is silently dropped.
4. Invokes pi-ai's streaming path with the OAuth credential, letting pi-ai apply the Claude Code identity layer. The bridge passes a `fetch` seam and disables pi-ai's built-in retries.
5. Relays pi-ai events back as native Anthropic SSE (`message_start`, `content_block_start`/`_delta`/`_stop`, `message_delta`, `message_stop`, `ping`) preserving text, thinking, tool_use, and input JSON deltas, usage, and stop reason. Non-streaming requests aggregate to a single Anthropic Messages response.

Client disconnects cancel the upstream request. Redirects are rejected. Upstream origins are constants owned by pi-ai.

## OAuth authentication

### Login

A workstation-only command (`task claude:login`) uses pi-ai's `loginAnthropic()`:

1. pi-ai starts the localhost callback server and prints the `claude.ai` authorization URL; the operator completes approval in the browser.
2. The returned access token, refresh token, and expiry are captured.
3. The script fetches the live model catalog and intersects it with the static allowlist, recording the confirmed set.
4. The script makes one bounded marker completion through the exact runtime request path (the pi-ai identity layer). If the response or error indicates third-party/extra-usage billing classification, login aborts with an explicit operator-facing message; no credential is persisted.
5. The complete credential record is persisted directly to OpenBao without printing it or writing a plaintext file.

### Refresh

Refresh uses pi-ai's refresh path with single-flight semantics inside the process. Rotated tokens replace old values only after durable OpenBao persistence (KV v2 check-and-set). On a CAS conflict the process re-reads and adopts the newer valid record.

## Billing and identity invariant

Inference is permitted only while Anthropic classifies the traffic as Claude Code subscription usage (plan limits), not extra usage. Operationally:

- Every upstream inference request flows through pi-ai's request path. The bridge must not hand-build identity headers or call `api.anthropic.com` outside pi-ai.
- An upstream error whose classification indicates third-party or extra-usage billing fails closed: the request fails, readiness drops, and the remedy is a pi-ai dependency update — never a header patch in bridge code.
- The caller bridge bearer (either accepted header form) is stripped before the upstream request; upstream authentication is exclusively the OAuth credential loaded from OpenBao. The bridge accepts no Anthropic credentials from callers, configuration, or environment.

## Credential record and persistence

Use OpenBao KV v2 path:

`aether/claude-bridge/credentials`

Logical schema:

```json
{
  "schemaVersion": 1,
  "access": "<oauth access token>",
  "refresh": "<oauth refresh token>",
  "expires": 0,
  "email": "<account email>",
  "models": ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"],
  "billingVerifiedAt": 0
}
```

Every field is secret, including model entitlements. Health and error responses must never serialize the record.

The pod authenticates to the existing `kubernetes-aether` OpenBao auth mount with a projected service-account token whose audience is `https://bao.home.shdr.ch`. A dedicated role is bound to the bridge service account and namespace. Its policy grants only create/read/update on the exact credential data path and read on the exact metadata path.

## Request and failure behavior

Before each request, the bridge obtains a valid credential through the single-flight refresh path.

On inference `401`:

1. Refresh once.
2. Persist the replacement credential.
3. Retry the inference request once.
4. Return a sanitized authorization error if retry fails.

Other statuses:

- `403`: definitive account/entitlement denial; recheck catalog once and mark not ready on confirmation.
- Third-party/extra-usage classification (400-class with that message shape): fail closed and mark not ready; the fix is a pi-ai update.
- `429`: preserve status and `Retry-After`; no provider fallback inside the bridge.
- Other `4xx`: pass through without retry.
- Network errors and `5xx`: fail without bridge-level replay; LiteLLM owns caller retries.
- Unknown routes and models: reject locally.

Inference timeouts follow the house long-streaming budget (900-second request and stream timeouts) with a shorter connection-setup bound. Request-body sizes are bounded.

## Kubernetes deployment

Deploy one replica with `Recreate` strategy so only one process owns refresh state.

Required properties:

- Dedicated `claude` namespace and service account.
- Non-root UID/GID.
- Read-only root filesystem.
- All Linux capabilities dropped.
- RuntimeDefault seccomp.
- No privilege escalation.
- Default service-account token automount disabled.
- Explicit projected OpenBao audience token only.
- Resource requests and limits comparable to `muse-bridge`/`grok-bridge`.
- Internal service and HTTPRoute at `claude.home.shdr.ch`.
- Immutable GitLab image digest.
- Cilium egress only to cluster DNS, `bao.home.shdr.ch`, `platform.claude.com` (token refresh), and `api.anthropic.com` (inference and model catalog) on required ports. `claude.ai` is workstation-login-only and is not an in-cluster egress destination.

The namespace Secret contains only the bridge caller bearer and non-credential configuration. Anthropic credentials live only in OpenBao and process memory.

## LiteLLM integration

Create one LiteLLM credential targeting `https://claude.home.shdr.ch/v1` with the bridge bearer (`CLAUDE_BRIDGE_API_KEY`).

Add one pinned entry per bootstrap-confirmed model:

- `claude/sonnet-5-5` → `anthropic/claude-sonnet-5-5`
- `claude/opus-5-5` → `anthropic/claude-opus-5-5`
- `claude/fable-5-1` → `anthropic/claude-fable-5-1`

Each entry carries the `claude_bridge_credential`, accurate metadata (1M context, 128K output, vision, thinking levels low→max), `timeout`/`stream_timeout` 900, and `cooldown_time: 0` so upstream errors surface unchanged. LiteLLM translates Chat Completions and Responses callers to Anthropic Messages at its boundary; the bridge does not duplicate that conversion.

No `router/*` group is added and no existing provider entry changes. The OMP virtual-key allowlist receives the confirmed `claude/*` names; Colony does not. No default agent model changes as part of this work.

## Testing

### Bridge behavior

Tests cover observable contracts, using pi-ai's `fetch` seam to inject local fake origins:

- Login capture, model-catalog intersection, and billing-marker abort behavior.
- Refresh single-flight, rotation, CAS persistence, and conflict adoption.
- OpenBao audience login, exact-path access, KV v2 CAS writes.
- Anthropic Messages → pi Context conversion: messages, system, tools, tool_choice, thinking budget, images, stop sequences; rejection of unsupported controls with `400`.
- pi events → Anthropic SSE mapping: text, thinking, tool_use deltas, usage, stop reason; no fabricated successful finish on upstream failure.
- Caller authorization replacement and constant-time comparison for both accepted header forms.
- Static/live model intersection and unknown-model rejection.
- `401` refresh-and-retry exactly once; `403`, `429`, other `4xx`, network, and `5xx` behavior.
- Extra-usage/third-party classification fails closed and drops readiness.
- Client cancellation and bounded request bodies.
- No API-key or PAYG fallback path exists in any branch.

Production origins remain constants and cannot be configured by callers.

### Aether validation

- OpenTofu formatting and validation.
- Taskfile parsing.
- Ansible syntax for virtual-key registration.
- Rendered LiteLLM YAML parsing and model-name uniqueness.
- Namespace-contract validation.
- Cilium policy permits only declared destinations.

### Live acceptance

Implementation is complete only when:

1. The user completes Anthropic OAuth authorization via `task claude:login`.
2. The credential record exists in OpenBao and no plaintext credential file exists.
3. The login billing check confirmed plan-limit classification and recorded `billingVerifiedAt`.
4. `/ready` is green and `/v1/models` contains only live, allowlisted models.
5. A streaming `/v1/messages` request through the direct bridge returns the requested marker, with thinking and tool blocks intact.
6. A Chat Completions request to the `claude/sonnet-5-5` LiteLLM model returns the marker, proving LiteLLM's Anthropic translation end to end.
7. Usage accounting and stop reasons survive the LiteLLM path.
8. The deployed image is pinned by digest and the rollout is ready.
9. OMP can select the new pins after `task configure:litellm-keys`; all other defaults are unchanged.

## Documentation

Update `docs/ai-ml.md` with the bridge ownership, credential path, pi-ai dependency policy, supported aliases, billing invariant, no-PAYG guarantee, login task, egress destinations, and troubleshooting boundaries. The bridge repository documents local development and runtime configuration without including account identifiers or credentials.
