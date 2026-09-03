# SuperGrok Subscription Bridge Design

## Status

Approved architecture for implementation. The bridge is private, single-tenant infrastructure behind Aether LiteLLM. It is not a public or multi-account xAI gateway.

## Goal

Expose the operator's SuperGrok subscription to Aether clients through pinned `supergrok/*` LiteLLM model names while keeping OAuth credentials server-side. Support the subscription's coding and chat models through xAI's Responses API. Existing Cursor and OpenRouter Grok routes remain independent; there is no automatic cross-provider pool and no PAYG fallback.

The bridge must refuse inference unless xAI reports that coding-data retention is opted out or the account is protected by organization-level Zero Data Retention.

## Source and compatibility basis

The protocol is based on two reviewed upstreams:

- xAI's official `xai-org/grok-build` repository at commit `72a61251fcffb464bcc687aeb5a998e5a98ec0c9`, including its documented browser/device OAuth support and `cli-chat-proxy.grok.com` inference path.
- `stnly/pi-grok` at commit `8b304e65c088f84ccb932959d97739245fe47d97`, which implements xAI device OAuth, refresh, OIDC validation, subscription-proxy headers, model discovery, account privacy inspection, and subscription-usage inspection under the MIT license.

The bridge will adapt only the minimum required behavior. Adapted code must retain source attribution and exact revisions. The implementation must not depend on a mutable npm install of either client at runtime.

xAI's official enterprise documentation distinguishes `cli-chat-proxy.grok.com` as the OAuth inference proxy from `api.x.ai`, which is the direct API-key path. All subscription inference must use the CLI proxy. The bridge must not accept, load, or fall back to an `XAI_API_KEY`.

## Non-goals

- No PAYG xAI API-key support or fallback.
- No Cursor or OpenRouter fallback.
- No account pooling or credential rotation between xAI accounts.
- No public or multi-tenant bridge.
- No image-generation, video-generation, audio, files, batches, realtime, or arbitrary `/v1/*` forwarding.
- No bridge-owned Chat Completions to Responses translation.
- No server-owned tool execution or agent loop.
- No automatic mutation of the account's coding-data privacy setting.
- No prompt, response, raw account payload, raw billing payload, or credential persistence in bridge logs.

## Repository ownership

Create a dedicated private `grok-bridge` GitLab repository beside `muse-bridge` and `antigravity-bridge`.

The bridge repository owns:

- Bun/TypeScript source and behavior tests.
- Device-code login and refresh implementation.
- OIDC discovery and ID-token validation.
- OpenBao credential persistence.
- Subscription-proxy request handling.
- Model discovery and static allowlisting.
- Privacy and usage inspection.
- Container image, Dockerfile, and GitLab CI.
- Runtime interface documentation.

Aether owns:

- The Kubernetes namespace and workload resources.
- Internal Gateway/HTTPRoute and DNS name.
- OpenBao policy and Kubernetes authentication role.
- Bridge bearer generation and Kubernetes Secret.
- Immutable image digest pin.
- LiteLLM credential and pinned `supergrok/*` model entries.
- OMP and Colony virtual-key allowlists.
- The workstation login task.

## Bridge interface

### `GET /health`

Unauthenticated process liveness. Returns success after process initialization even when credentials, privacy state, or upstream access are unavailable. It reveals no account, token, quota, or model information.

### `GET /ready`

Unauthenticated readiness. Returns success only when:

- OpenBao authentication succeeded.
- A structurally valid credential record was loaded.
- The OAuth credential is not expired beyond refreshability or definitively revoked.
- The most recent verified account state reports `codingDataRetentionOptOut: true` or `isZdr: true`.
- At least one approved coding/chat model is available to the account.

Transient upstream failures do not permanently invalidate readiness. A definitive authorization failure, missing Grok Code access, or unsafe privacy state does.

The response contains only coarse status fields. It must not return identity, raw entitlement, quota, or token metadata.

### `GET /v1/models`

Requires the bridge bearer. Returns an OpenAI-compatible catalog containing the intersection of the live subscription catalog and this static allowlist:

- `supergrok/grok-composer-2.5-fast`
- `supergrok/grok-build`
- `supergrok/grok-4.6`
- `supergrok/grok-4.3`
- `supergrok/grok-4.20-0309-reasoning`
- `supergrok/grok-4.20-0309-non-reasoning`
- `supergrok/grok-4.20-multi-agent-0309`

A model absent from the account catalog is omitted and rejected. Newly discovered model IDs are never exposed until explicitly added to the static allowlist in code and Aether's LiteLLM configuration.

### `POST /v1/responses`

Requires the bridge bearer. This is the only inference endpoint.

The bridge:

1. Requires a bounded JSON request body.
2. Validates the public `supergrok/*` model against the current allowlisted catalog.
3. Rewrites the body model to the upstream xAI model ID.
4. Removes caller authorization and all xAI/Grok identity headers.
5. Injects the current OAuth access token and the pinned Grok CLI identity headers.
6. Sets `x-grok-model-override` from the validated mapping, never caller input.
7. Sends the request to the fixed `https://cli-chat-proxy.grok.com/v1/responses` endpoint.
8. Relays JSON and SSE responses without translating response items, tool calls, reasoning, usage, or finish state.

Redirects are rejected. Upstream origins are constants. Client disconnects cancel the upstream request.

LiteLLM owns Chat Completions compatibility. Its per-model `openai/responses/` provider prefix activates the pinned LiteLLM 1.92 Chat-to-Responses bridge for `/v1/chat/completions` requests. The bridge does not duplicate that protocol conversion.

### `GET /usage`

Requires the bridge bearer. Resolves the current account through the subscription proxy, validates the returned user ID before placing it in a header, and requests `/billing?format=credits`. It returns only normalized tier and quota numbers.

The billing endpoint is not part of xAI's documented public API. Failure, schema drift, or unavailable usage data does not affect inference readiness. Raw user and billing payloads are bounded, never logged, and never persisted.

## OAuth authentication

### Device login

A workstation-only command performs xAI's RFC 8628 device flow:

1. Request a device code from `https://auth.x.ai/oauth2/device/code` using the reviewed public Grok client ID and approved scopes.
2. Show only the trusted verification URI, user code, and expiry.
3. Poll `https://auth.x.ai/oauth2/token` using the server interval, RFC `slow_down` behavior, bounded cancellation, and expiry.
4. Validate returned access token, refresh token, expiry, and ID token.
5. Validate OIDC discovery endpoints as HTTPS on `x.ai` or its subdomains.
6. Require ES256 and validate the ID-token signature, issuer, audience, nonce/state where applicable, and expiry with bounded clock skew.
7. Fetch `/user` through the CLI proxy and require privacy opt-out or ZDR.
8. Fetch and intersect the live model catalog.
9. Persist the complete credential record directly to OpenBao without printing it or writing a plaintext file.

Scopes are limited to `openid profile email offline_access grok-cli:access api:access`. Conversation scopes are omitted because the bridge makes stateless Responses calls and does not attach xAI server-side conversation IDs.

### Refresh

Refresh uses the discovered, origin-pinned token endpoint with `grant_type=refresh_token`. Rotated refresh and ID tokens replace old values only after validation and durable OpenBao persistence.

After refresh, the bridge rechecks account privacy and model availability before returning to ready state. A refresh that succeeds cryptographically but produces an unsafe privacy state must not enable inference.

## Credential record and persistence

Use OpenBao KV v2 path:

`aether/grok-bridge/credentials`

Logical schema:

```json
{
  "schemaVersion": 1,
  "access": "<oauth access token>",
  "refresh": "<oauth refresh token>",
  "expires": 0,
  "idToken": "<validated oidc id token>",
  "tokenEndpoint": "https://auth.x.ai/...",
  "accountId": "<verified account id>",
  "email": "<verified email>",
  "privacy": {
    "codingDataRetentionOptOut": true,
    "isZdr": false,
    "checkedAt": 0
  },
  "models": ["grok-4.6"]
}
```

Every field is secret, including model entitlements and privacy state. Health and error responses must never serialize the record.

The pod authenticates to the existing `kubernetes-aether` OpenBao auth mount with a projected service-account token whose audience is `https://bao.home.shdr.ch`. A dedicated role is bound to the bridge service account and namespace. Its policy grants only create/read/update on the exact credential data path and read on the exact metadata path.

Writes use KV v2 check-and-set. A refreshed credential becomes active only after durable persistence. On a CAS conflict, the process re-reads and adopts the newer valid record. Refresh is single-flight within the process.

## Privacy invariant

Inference is permitted only when the latest verified `/user` response establishes one of:

- `codingDataRetentionOptOut === true`
- `isZdr === true`

Missing, malformed, stale, or contradictory privacy data is unsafe and fails closed. The bridge never calls the privacy mutation endpoint. The user must change privacy through an xAI-controlled client or account surface, then rerun login or allow the next refresh/check to observe it.

Privacy is verified during login, startup, refresh, and periodically while running. The periodic interval is bounded and configurable; stale privacy state expires rather than remaining trusted indefinitely.

## Request and failure behavior

Before each request, the bridge obtains a valid credential through a single-flight refresh path and confirms the privacy state is still within its trust interval.

On inference `401`:

1. Refresh once.
2. Recheck privacy and models.
3. Persist the replacement credential.
4. Retry the inference request once.
5. Return a sanitized authorization error if retry fails.

Other statuses:

- `402`: pass through; never introduce PAYG credentials.
- `403`: recheck account entitlement/privacy once; mark not ready on definitive denial.
- `429`: preserve status and `Retry-After`; no provider fallback inside the bridge.
- Other `4xx`: pass through without retry.
- Network errors and `5xx`: fail without bridge-level replay; LiteLLM owns caller retries.
- Unknown routes and models: reject locally.

Inference timeout must support the official Grok Build recommendation of long-lived SSE while remaining finite. Connection setup, OAuth, account, model, and billing requests use shorter independent timeouts. Request-body and metadata-response sizes are bounded.

## Kubernetes deployment

Deploy one replica with `Recreate` strategy so only one process owns refresh state.

Required properties:

- Dedicated `grok` namespace and service account.
- Non-root UID/GID.
- Read-only root filesystem.
- All Linux capabilities dropped.
- RuntimeDefault seccomp.
- No privilege escalation.
- Default service-account token automount disabled.
- Explicit projected OpenBao audience token only.
- Resource requests and limits comparable to `muse-bridge`.
- Internal service and HTTPRoute at `grok.home.shdr.ch`.
- Immutable GitLab image digest.
- Rollout annotations derived from image and non-secret configuration.
- Cilium egress only to cluster DNS, OpenBao, `auth.x.ai`, and `cli-chat-proxy.grok.com` on required ports.

The namespace Secret contains only the bridge caller bearer and non-credential configuration. xAI credentials live only in OpenBao and process memory.

## LiteLLM integration

Create one LiteLLM credential targeting `https://grok.home.shdr.ch/v1` with the bridge bearer.

Add only pinned provider aliases for models confirmed by live login. Each entry uses the Responses API upstream behavior so LiteLLM translates Chat Completions callers at its boundary. Public names use the `supergrok/` prefix and are never aliased into the existing Cursor or OpenRouter names.

No `router/grok-*` group is added. Existing `cursor/grok-4.6` and `openrouter/grok-4` remain unchanged. A caller must opt into SuperGrok explicitly, preventing silent billing or data-policy changes.

OMP and Colony virtual-key allowlists receive the confirmed `supergrok/*` names. No default agent model changes as part of this work.

## Testing

### Bridge behavior

Tests cover observable contracts:

- Trusted device verification URL and RFC 8628 polling states.
- Pending, slow-down, denial, expiry, cancellation, malformed response, and timeout behavior.
- OIDC origin pinning, ES256 signature verification, issuer/audience/expiry validation, key rotation, and invalid-token rejection.
- Refresh-token rotation and single-flight refresh.
- OpenBao audience login, exact-path access, KV v2 CAS writes, and conflict adoption.
- Privacy opt-out and ZDR acceptance.
- Missing, stale, false, and malformed privacy state rejection.
- Static/live model intersection and unknown-model rejection.
- Caller authorization replacement and constant-time comparison.
- Required CLI identity headers and validated model override.
- Responses JSON and SSE pass-through.
- Client cancellation and bounded request bodies.
- `401` refresh-and-retry exactly once.
- `402`, `403`, `429`, other `4xx`, network, and `5xx` behavior.
- Usage normalization and defensive failure against endpoint/schema drift.
- No API-key or PAYG fallback path.

Tests use local fake HTTP origins injected through explicit test seams. Production origins remain constants and cannot be configured by callers.

### Aether validation

- OpenTofu formatting and validation.
- Taskfile parsing.
- Ansible syntax for virtual-key registration.
- Rendered LiteLLM YAML parsing and model-name uniqueness.
- Namespace-contract validation.
- Cilium policy permits only declared destinations.

### Live acceptance

Implementation is complete only when:

1. The user completes xAI device authorization.
2. The credential record exists in OpenBao and no plaintext credential file exists.
3. `/ready` proves safe privacy state and at least one allowed model.
4. `/v1/models` contains only live, allowlisted subscription models.
5. A streaming `/v1/responses` request returns the requested marker through the direct bridge.
6. A Chat Completions request to the corresponding `supergrok/*` LiteLLM model returns the marker, proving LiteLLM translation.
7. Tool calls and reasoning items survive the LiteLLM path.
8. `/usage` returns normalized subscription quota when the upstream endpoint is available; unavailability is reported without breaking readiness.
9. The deployed image is pinned by digest and all rollouts are ready.
10. A direct inspection confirms requests used `cli-chat-proxy.grok.com`, with no request sent to `api.x.ai`.

## Documentation

Update `docs/ai-ml.md` with the bridge ownership, credential path, supported aliases, privacy invariant, no-PAYG guarantee, login task, and troubleshooting boundaries. Document usage as best-effort because the billing endpoint is not public API. The bridge repository documents local development and runtime configuration without including account identifiers or credentials.
