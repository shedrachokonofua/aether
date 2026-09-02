# Muse Subscription Bridge Design

## Status

Approved architecture for implementation. The bridge is private, single-tenant infrastructure behind LiteLLM. It is not a public or multi-user Meta gateway.

## Goal

Expose the operator's Muse Code subscription to Aether's OMP and Colony clients through LiteLLM while keeping subscription credentials server-side. Add two distinct LiteLLM routing groups:

- `router/muse-spark-1.3` for normal Muse Spark 1.3 traffic.
- `router/muse-spark-1.3-contributor` for contributor traffic whose prompts may be used for training.

The normal and contributor groups must never share deployments.

## Source and compatibility basis

The credential flow is based on `can1357/oh-my-pi` pull request #10498 at reviewed head commit `d51f6b0293b3c7ce299eb921b5846aaa45663e73`.

That change implements:

1. Meta OAuth 2.0 device authorization through `auth.meta.com`.
2. Exchange of the account grant at `https://api.meta.ai/muse-code/key`.
3. Retrieval of the subscription-backed Model API key.
4. OAuth refresh and subscription-key re-minting.
5. Detection of inactive subscriptions and quota reporting.

The bridge will vendor only the minimum device-flow, response-validation, and refresh implementation needed for this flow. Vendored code must name the upstream repository, pull request, and exact commit. After the change is merged and released through `@oh-my-pi/pi-ai`, the vendored module should be replaced with the published export in one clean cutover.

Meta documents Muse Code subscriptions as working through the Muse Code CLI. This bridge is therefore an operator-approved private integration with uncertain provider-policy support. It must remain single-tenant, internal, and protected behind LiteLLM. It must not become a public gateway or a multi-user product.

## Non-goals

- No PAYG fallback. Requests fail when subscription access is exhausted or unavailable.
- No account pooling or automatic rotation between Meta accounts.
- No public exposure of the bridge endpoint.
- No OpenAI Responses API translation.
- No server-owned tool execution or agent loop.
- No prompt, response, or credential persistence in bridge logs.
- No general Meta Model API proxy. Only explicitly allowlisted Muse subscription models are accepted.
- No changes to OMP itself or to pull request #10498.

## Repository ownership

Create a dedicated `muse-bridge` GitLab repository beside `antigravity-bridge`.

The bridge repository owns:

- Bun/TypeScript source and tests.
- The workstation device-login command.
- Container image and Dockerfile.
- GitLab CI checks and amd64 image publication.
- Its design and operational instructions.

Aether owns:

- Kubernetes namespace and workload resources.
- Internal Gateway/HTTPRoute and DNS name.
- OpenBao policy and Kubernetes authentication role.
- Bridge bearer generation and Kubernetes Secret.
- Immutable image digest pin.
- LiteLLM credential, deployments, routing groups, aliases, and virtual-key allowlists.
- A task that runs the workstation login command and writes the result to OpenBao.

## Bridge interface

### `GET /health`

Unauthenticated liveness endpoint. It returns success after process
initialization even when credentials or upstream access are unavailable, so a
credential failure cannot cause a Kubernetes restart loop. The response reveals
no account, quota, token, or upstream-response data.

### `GET /ready`

Unauthenticated readiness endpoint. It returns success only when:

- OpenBao authentication succeeded.
- A valid credential record was loaded.
- The credential has not been marked invalid by a definitive subscription or authorization failure.

Transient upstream request failures do not permanently invalidate readiness.
Definitive inactive-subscription or revoked-credential responses do.

### `GET /v1/models`

Requires the bridge bearer token. Returns an OpenAI-compatible model list containing only:

- `muse-subscription/muse-spark-1.3`

The catalog is static and allowlisted. It is not copied from Meta's full account catalog.

### `POST /v1/chat/completions`

Requires the bridge bearer token.

Accepted model:

- Public: `muse-subscription/muse-spark-1.3`
- Upstream rewrite: `muse-spark-1.3`

The bridge validates that the request is JSON and that the requested model is allowlisted, replaces the model field, strips caller authorization and hop-by-hop headers, injects the current subscription API key, and forwards the request to `https://api.meta.ai/v1/chat/completions`.

Meta already speaks the required OpenAI-compatible protocol. The bridge relays ordinary JSON responses and SSE streams without translating message, tool-call, usage, reasoning, or finish-reason payloads. Tool execution remains client-owned.

Unknown paths and models fail locally. Redirects from authentication, key-exchange, and inference endpoints are rejected. Upstream hostnames are constants, never caller-controlled.

## Authentication

### Caller authentication

`BRIDGE_API_KEY` protects every `/v1/*` route. The key is generated by Aether and stored in a namespace-local Kubernetes Secret. Comparisons use a constant-time method after length normalization.

The public Gateway must not route directly to the bridge. LiteLLM is the joined front door. Direct bridge access is for internal verification only.

### Meta device login

A workstation-only command performs the approved PR flow:

1. Request a device code from `https://auth.meta.com/oidc/device/authorization/` using the public Muse client ID from PR #10498.
2. Show only the trusted verification URI and user code.
3. Poll `https://auth.meta.com/oidc/device/token/` according to RFC 8628, including the default interval and `slow_down` handling.
4. Validate the token response.
5. Exchange the account access token at `https://api.meta.ai/muse-code/key` with the required API version header.
6. Reject missing keys, inactive subscriptions, untrusted URLs, invalid JSON, invalid expirations, and setup/payment-action responses.
7. Store the complete credential record directly in OpenBao without printing it or writing a plaintext file.

The earlier manually created Model API key is not used. Meta documents additional manually created keys as PAYG credentials, which explains the observed `billing_not_configured` response and does not exercise the Muse subscription.

## Credential record and persistence

Use a versioned record at the dedicated OpenBao KV v2 path:

`aether/muse-bridge/credentials`

Logical schema:

```json
{
  "schemaVersion": 1,
  "access": "<oauth access token>",
  "refresh": "<oauth refresh token>",
  "expires": 0,
  "apiKey": "<subscription Model API key>",
  "accountId": "<optional>",
  "email": "<optional>"
}
```

Every field is secret. Logs and health responses must never serialize the record.

The bridge authenticates to the existing `kubernetes-aether` OpenBao auth mount with a projected service-account token whose audience is `https://bao.home.shdr.ch`. A dedicated role is bound to the bridge service account and namespace. Its policy grants only:

- `create`, `read`, and `update` on the exact credential data path.
- `read` on the exact credential metadata path when required for KV version handling.

No list, delete, or access to sibling paths is granted.

Writes use KV v2 check-and-set with the version read alongside the active record. A successful OAuth refresh is adopted in memory only after the complete replacement record is durably written. On a CAS conflict, the bridge re-reads the record and uses the newer valid version rather than overwriting it. Refresh is single-flight within the process.

OpenBao client tokens remain in memory, are renewed or reacquired before expiry, and are never written to disk. The pod uses an explicit projected token volume; default service-account token automount remains disabled.

## Refresh and request behavior

The bridge normally uses the minted subscription API key. Before an OAuth credential expires, one request performs a serialized OAuth refresh, re-mints the subscription key, persists the replacement record, and then serves waiting requests.

On an inference `401`:

1. Refresh and re-mint once.
2. Persist the replacement credential.
3. Retry the inference request once with the new key.
4. Return a sanitized upstream error if the retry fails.

No other status triggers credential rotation.

Status behavior:

- `401`: one refresh-and-retry, then fail.
- `402`: pass through; never substitute PAYG credentials.
- `403` inactive/revoked subscription: mark credentials invalid and fail readiness.
- `429`: preserve status and `Retry-After`; no PAYG fallback.
- Other upstream `4xx`: pass through without retry.
- Network errors and `5xx`: fail without bridge-level replay; LiteLLM owns cross-deployment retries and fallbacks.
- Client disconnect during SSE: cancel the upstream request.

Request and upstream timeouts are bounded and configurable. The default must support agentic turns without allowing unbounded sockets. Request-body size is bounded. Exact defaults follow the established Antigravity bridge and Aether LiteLLM timeout conventions unless Meta requires a stricter documented limit.

## Kubernetes deployment

Deploy one replica with a `Recreate` strategy so only one process owns credential refresh at a time.

Required properties:

- Dedicated namespace and service account.
- Non-root UID/GID.
- Read-only root filesystem.
- All Linux capabilities dropped.
- RuntimeDefault seccomp.
- No privilege escalation.
- No default service-account token.
- Explicit projected OpenBao audience token only.
- Resource requests and limits comparable to `antigravity-bridge`.
- Internal service and HTTPRoute at `muse.home.shdr.ch`.
- Immutable GitLab image digest.
- Rollout annotations derived from image and non-secret configuration.

The bridge Secret contains only its caller bearer and non-credential configuration. Meta credentials live only in OpenBao and bridge memory.

## LiteLLM routing

### Provider pins

Normal subscription/provider pins:

- `muse-subscription/muse-spark-1.3`
- `commandcode/muse-spark-1.3`
- `clinepass/muse-spark-1.3`

Contributor pins:

- `commandcode/muse-spark-1.3-contributor`
- `clinepass/muse-spark-1.3-contributor`
- `opencode-go/muse-spark-1.3-contributor`

The Command Code catalog currently advertises both `meta/muse-spark-1.3` and `meta/muse-spark-1.3-contributor`. Clinepass advertises both. OpenCode Go advertises `muse-spark-1.3-contributor`.

### Routing groups

`router/muse-spark-1.3` contains:

- Muse subscription bridge.
- Command Code normal deployment.
- Clinepass normal deployment.

`router/muse-spark-1.3-contributor` contains:

- Command Code contributor deployment.
- Clinepass contributor deployment.
- OpenCode Go contributor deployment.

Both use latency-based routing with the existing bounded retry, fallback, cooldown, and latency-cache conventions.

These are streaming-agent pools. `stream: true` is their supported contract because Clinepass and OpenCode Go currently fail Muse non-stream requests. The Muse bridge and Command Code pins additionally support non-stream requests. Explicit provider pins remain available for protocol-specific diagnosis.

Plain aliases map as follows:

- `muse-spark-1.3` → `router/muse-spark-1.3`
- `muse-spark-1.3-contributor` → `router/muse-spark-1.3-contributor`

Remove all Muse Spark 1.2 Contributor deployments, router configuration, aliases, virtual-key entries, and current documentation in the same cutover. No compatibility aliases remain.

OMP and Colony virtual keys receive both router names, both plain aliases, and
all six provider pins listed above. Contributor routes remain documented as
public-work-only. No default Colony agent model changes as part of this work.

## Testing

### Bridge tests

Test through the same external seams used by callers:

- Device authorization validation and trusted verification host.
- RFC 8628 pending, slow-down, timeout, cancellation, and omitted-interval behavior.
- Token and key response schema validation.
- Inactive subscription and setup-action failures.
- Refresh-token preservation when omitted and replacement when rotated.
- Subscription-key re-minting.
- OpenBao login, exact-path access, KV version parsing, CAS write, conflict reload, and write-before-adopt invariant.
- Single-flight concurrent refresh.
- Constant-time caller authentication.
- Unknown route/model rejection.
- Authorization and hop-by-hop header stripping.
- Model rewrite.
- JSON completion relay.
- SSE byte-stream relay and client cancellation.
- One-time `401` refresh/retry.
- `402`, `403`, and `429` behavior without PAYG fallback.
- Liveness remains successful during credential failures while readiness fails.
- No secret-bearing fields in health, readiness, or structured logs.

CI runs type checking and the complete deterministic test suite before building the amd64 image. Network interactions in CI use local test servers or injected fetch implementations; CI never uses the real subscription.

### Live verification

After an operator completes the device flow:

1. Confirm the OpenBao record exists without printing its value.
2. Deploy the immutable bridge image through Aether.
3. Confirm bridge rollout and readiness.
4. Confirm the protected model catalog contains only the normal subscription pin.
5. Exercise direct bridge non-stream and SSE completions.
6. Apply the LiteLLM config and synchronize OMP/Colony virtual keys.
7. Exercise every new provider pin with its supported protocol.
8. Exercise both router groups with streaming requests repeatedly enough to observe each deployment or inspect LiteLLM deployment metadata.
9. Confirm the normal router never selects a Contributor backend and the Contributor router never selects the Muse subscription.
10. Confirm a quota response does not fall back to PAYG.

## Rollout order

1. Create and validate `muse-bridge` locally.
2. Create its GitLab project and push the reviewed source.
3. Build and publish the image; resolve its immutable digest.
4. Add Aether OpenBao policy/role and Kubernetes deployment declarations.
5. Apply only the credential/deployment prerequisites.
6. Run the workstation device login and store the credential in OpenBao.
7. Roll out and verify the bridge directly.
8. Replace Muse 1.2 declarations with the two Muse 1.3 routing groups.
9. Apply LiteLLM changes and synchronize keys.
10. Verify every provider pin and both routers.
11. Update authoritative docs and push Aether.

No live patching is part of the rollout.

## Acceptance criteria

- Aether can call `muse-subscription/muse-spark-1.3` through LiteLLM using the Muse subscription rather than a PAYG API key.
- OAuth and minted subscription credentials survive pod restarts and successful token rotation through OpenBao persistence.
- The bridge never falls back to PAYG.
- Normal and Contributor deployments are in separate routing groups with no shared backend.
- Both router groups work for streaming OMP/Colony requests.
- Every provider pin is independently diagnosable.
- All 1.2 Contributor configuration is removed.
- Secrets never appear in repository plaintext, process logs, health responses, test fixtures containing real values, or command output.
- The deployed image is pinned by digest and both rollouts complete successfully.
