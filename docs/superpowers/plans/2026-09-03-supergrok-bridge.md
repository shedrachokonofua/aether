# SuperGrok Subscription Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a private SuperGrok OAuth bridge that exposes approved coding/chat models through pinned `supergrok/*` LiteLLM names without API-key billing or unsafe coding-data retention.

**Architecture:** A dedicated Bun service performs xAI device OAuth, validates OIDC tokens, stores rotating credentials in OpenBao, enforces account privacy, intersects live models with a static allowlist, and relays the native Responses API to `cli-chat-proxy.grok.com`. Aether deploys the service and configures LiteLLM to translate Chat Completions callers at its boundary; SuperGrok never joins Cursor or OpenRouter pools.

**Tech Stack:** Bun 1.3.14, TypeScript 5.9, Web Crypto, `bun:test`, xAI OAuth/OIDC and CLI inference proxy, OpenBao KV v2 and Kubernetes auth, OpenTofu, Kubernetes, Cilium Gateway API, LiteLLM, Ansible, GitLab CI.

**Spec:** `docs/superpowers/specs/2026-09-03-supergrok-bridge-design.md`

## Global Constraints

- Adapt protocol behavior from `xai-org/grok-build` commit `72a61251fcffb464bcc687aeb5a998e5a98ec0c9` and `stnly/pi-grok` commit `8b304e65c088f84ccb932959d97739245fe47d97`; retain attribution.
- Subscription inference goes only to `https://cli-chat-proxy.grok.com/v1/responses`.
- Never load, accept, or fall back to `XAI_API_KEY`, Cursor, OpenRouter, or another account.
- Refuse readiness and inference unless `codingDataRetentionOptOut === true` or `isZdr === true` from a verified `/user` response.
- Expose only the static coding/chat allowlist intersected with the live account catalog.
- The bridge exposes native `/v1/responses`; LiteLLM owns Chat Completions translation.
- Persist credentials at OpenBao logical path `aether/grok-bridge/credentials` using KV v2 CAS.
- Never print credentials or persist raw account/billing payloads, prompts, or responses.
- Run repository commands through Aether's Nix development shell.
- Deploy through declared Aether IaC; no live patching.
- Preserve unrelated user changes in the Aether worktree.

---

### Task 1: Bootstrap the bridge and xAI OAuth module

**Files:**
- Create: `../grok-bridge/package.json`
- Create: `../grok-bridge/tsconfig.json`
- Create: `../grok-bridge/.gitignore`
- Create: `../grok-bridge/src/types.ts`
- Create: `../grok-bridge/src/safe-fetch.ts`
- Create: `../grok-bridge/src/bounded-json.ts`
- Create: `../grok-bridge/src/oauth.ts`
- Create: `../grok-bridge/test/oauth.test.ts`
- Create: `../grok-bridge/test/safe-fetch.test.ts`

**Interfaces:**
- Consumes: fixed xAI issuer `https://auth.x.ai`, device/token endpoints, reviewed public client ID, and scope `openid profile email offline_access grok-cli:access api:access`.
- Produces:

```ts
export interface PrivacyState {
  codingDataRetentionOptOut: boolean;
  isZdr: boolean;
  checkedAt: number;
}

export interface GrokCredentials {
  schemaVersion: 1;
  access: string;
  refresh: string;
  expires: number;
  idToken: string;
  tokenEndpoint: string;
  accountId: string;
  email: string;
  privacy: PrivacyState;
  models: string[];
}

export interface OAuthTokens {
  access: string;
  refresh: string;
  expires: number;
  idToken: string;
  tokenEndpoint: string;
}

export class GrokOAuthClient {
  login(onAuth: (verificationUri: string, userCode: string) => void, signal?: AbortSignal): Promise<OAuthTokens>;
  refresh(credentials: Pick<GrokCredentials, "refresh" | "tokenEndpoint">, signal?: AbortSignal): Promise<OAuthTokens>;
}
```

- [ ] **Step 1: Create the private bridge repository and toolchain.** Initialize `../grok-bridge` with Bun/TypeScript scripts `start`, `login`, `typecheck`, `test`, and `check`; pin `@types/bun` 1.3.14 and TypeScript 5.9.3. Initialize Git and create private GitLab project `so/grok-bridge` without committing credentials.
- [ ] **Step 2: Write failing OAuth and safe-fetch tests.** Cover trusted xAI origins, rejected HTTP/non-xAI discovery endpoints, bounded bodies, rejected redirects, PKCE shape, device pending/slow-down/denial/expiry/cancellation, missing token fields, refresh rotation, ES256 JWKS validation, issuer/audience/expiry failures, and one uncached JWKS retry on unknown `kid`.

```ts
expect(validateXaiEndpoint("https://auth.x.ai/oauth2/token", "token_endpoint"))
  .toBe("https://auth.x.ai/oauth2/token");
expect(() => validateXaiEndpoint("https://attacker.example/token", "token_endpoint"))
  .toThrow("Refusing non-xAI");
```

- [ ] **Step 3: Run focused tests and confirm the expected failure.** Run `nix develop /Users/shdrch/projects/aether --command bun test test/oauth.test.ts test/safe-fetch.test.ts`; expect module-resolution failures because implementation files do not exist.
- [ ] **Step 4: Implement bounded HTTP, PKCE, device polling, discovery, JWKS verification, token parsing, and refresh.** Use Web Crypto only; pin HTTPS origins; apply 15-second request timeouts and 64-KiB auth response limits; never log response bodies. Attribution comments name both upstream commits.
- [ ] **Step 5: Re-run focused tests and type checking.** Run `nix develop /Users/shdrch/projects/aether --command bun test test/oauth.test.ts test/safe-fetch.test.ts` and `nix develop /Users/shdrch/projects/aether --command bun run typecheck`; expect success.
- [ ] **Step 6: Commit.** Commit bridge files as `feat: add SuperGrok OAuth flow`.

### Task 2: Add account privacy, model discovery, and usage clients

**Files:**
- Create: `../grok-bridge/src/proxy-client.ts`
- Create: `../grok-bridge/src/models.ts`
- Create: `../grok-bridge/src/usage.ts`
- Create: `../grok-bridge/test/proxy-client.test.ts`
- Create: `../grok-bridge/test/models.test.ts`
- Create: `../grok-bridge/test/usage.test.ts`

**Interfaces:**
- Consumes: OAuth access token, `PrivacyState`, and fixed `https://cli-chat-proxy.grok.com/v1` origin.
- Produces:

```ts

export interface GrokAccount {
  accountId: string;
  email: string;
  hasGrokCodeAccess: boolean;
  privacy: PrivacyState;
}

export interface AllowedModel {
  publicId: `supergrok/${string}`;
  upstreamId: string;
}

export interface UsageSnapshot {
  tier?: string;
  used?: number;
  limit?: number;
  remaining?: number;
  resetAt?: number;
}

export class GrokProxyClient {
  inspectAccount(access: string, signal?: AbortSignal): Promise<GrokAccount>;
  discoverModels(access: string, signal?: AbortSignal): Promise<AllowedModel[]>;
  usage(access: string, accountId: string, signal?: AbortSignal): Promise<UsageSnapshot>;
}
```

- [ ] **Step 1: Write failing account/privacy tests.** Verify required Grok identity headers, fixed origin, bearer injection, bounded `/user` response parsing, `codingDataRetentionOptOut` and `isZdr`, missing/false privacy rejection, Grok Code entitlement, and absence of the privacy mutation endpoint.
- [ ] **Step 2: Write failing model tests.** Use a catalog containing allowed, unknown, media, and malformed entries. Require an exact intersection with the eight model IDs in the spec and `supergrok/` public naming; unknown live models remain hidden.
- [ ] **Step 3: Write failing usage tests.** Verify printable-ASCII account-ID validation before `x-userid`, `/billing?format=credits`, bounded/depth-limited JSON parsing, normalized numeric output, and defensive errors for schema drift. Confirm usage failure is distinguishable from readiness failure.
- [ ] **Step 4: Run focused tests and confirm failure.** Run `nix develop /Users/shdrch/projects/aether --command bun test test/proxy-client.test.ts test/models.test.ts test/usage.test.ts`; expect missing implementation exports.
- [ ] **Step 5: Implement the proxy client and allowlist.** Send the reviewed `grok-shell` identity, version, mode, token-auth, and authenticate-response headers. Make the client version an explicit non-secret environment setting with the reviewed version as default. Do not implement `PUT /privacy/coding-data-retention`.
- [ ] **Step 6: Re-run focused tests and type checking.** Expect all focused tests and `bun run typecheck` to pass.
- [ ] **Step 7: Commit.** Commit as `feat: enforce SuperGrok privacy and catalog`.

### Task 3: Add OpenBao persistence and credential coordination

**Files:**
- Create: `../grok-bridge/src/bao.ts`
- Create: `../grok-bridge/src/credentials.ts`
- Create: `../grok-bridge/test/bao.test.ts`
- Create: `../grok-bridge/test/credentials.test.ts`

**Interfaces:**
- Consumes: `GrokOAuthClient`, `GrokProxyClient`, `GrokCredentials`, and exact OpenBao path.
- Produces:

```ts
export interface VersionedCredentials {
  version: number;
  credentials: GrokCredentials;
}

export interface TokenProvider {
  token(signal?: AbortSignal): Promise<string>;
}

export class BaoCredentialStore {
  read(signal?: AbortSignal): Promise<VersionedCredentials>;
  write(credentials: GrokCredentials, expectedVersion: number, signal?: AbortSignal): Promise<number>;
}

export class GrokCredentialManager {
  initialize(signal?: AbortSignal): Promise<void>;
  ready(): boolean;
  readiness(): { ready: boolean; reason?: "missing_credentials" | "unsafe_privacy" | "no_models" | "invalid_credentials" };
  current(signal?: AbortSignal): Promise<GrokCredentials>;
  refreshAfterUnauthorized(failedAccess: string, signal?: AbortSignal): Promise<GrokCredentials>;
  usage(signal?: AbortSignal): Promise<UsageSnapshot>;
}
```

- [ ] **Step 1: Write failing OpenBao tests.** Cover operator-token and Kubernetes-auth providers, projected JWT use, exact mount/path requests, KV v2 metadata parsing, CAS writes, 403/404 errors, and token renewal/reacquisition without disk persistence.
- [ ] **Step 2: Write failing manager tests.** Cover startup validation, five-minute early token refresh, 15-minute privacy/model trust expiry, fail-closed privacy, no-model readiness, write-before-adopt, CAS conflict adoption, concurrent single-flight refresh, stale-access `401` races, and usage failures that do not change readiness.
- [ ] **Step 3: Run focused tests and confirm failure.** Run the two test files through the Aether Nix shell; expect missing exports.
- [ ] **Step 4: Implement store and manager.** Reuse the established Muse KV v2 boundary but keep Grok validation separate. Privacy/catalog rechecks create a replacement CAS record. A stale or unverifiable privacy state makes `current()` fail without sending inference upstream.
- [ ] **Step 5: Re-run focused tests and type checking.** Expect success.
- [ ] **Step 6: Commit.** Commit as `feat: persist SuperGrok credentials in OpenBao`.

### Task 4: Add the authenticated Responses proxy

**Files:**
- Create: `../grok-bridge/src/server.ts`
- Create: `../grok-bridge/src/index.ts`
- Create: `../grok-bridge/test/server.test.ts`

**Interfaces:**
- Consumes: `GrokCredentialManager`, `AllowedModel`, and fixed proxy origin.
- Produces:

```ts
export interface ServerDependencies {
  credentials: GrokCredentialManager;
  bridgeApiKey: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

export function createHandler(dependencies: ServerDependencies):
  (request: Request) => Promise<Response>;
```

- [ ] **Step 1: Write failing route/authentication tests.** Cover `/health`, `/ready`, `/v1/models`, `/v1/responses`, `/usage`, unknown paths, constant-time bearer checks, 16-MiB body rejection by header and actual bytes, invalid JSON, and unknown models.
- [ ] **Step 2: Write failing proxy tests.** Assert the upstream URL is exactly `https://cli-chat-proxy.grok.com/v1/responses`; public model rewrite; caller authorization/xAI-header stripping; required identity headers; validated `x-grok-model-override`; safe response headers; JSON/SSE relay; cancellation; and absence of `/v1/chat/completions` or generic path forwarding.
- [ ] **Step 3: Write failing error tests.** Verify `401` refresh-and-retry once, `402` pass-through, `403` entitlement recheck, `429` plus `Retry-After`, other `4xx`, network errors, `5xx`, and no API-key/provider fallback.
- [ ] **Step 4: Run `test/server.test.ts` and confirm failure.** Expect the handler module to be absent.
- [ ] **Step 5: Implement the handler and entry point.** Keep connect/auth requests short; relay inference SSE with a 610-second inter-chunk idle timeout and client cancellation rather than a short total request timeout. Never log bodies or authorization. Read only `PORT`, bridge/OpenBao settings, projected JWT path, privacy TTL, and Grok client version.
- [ ] **Step 6: Re-run server tests, the complete test suite, and type checking.** Run `bun run check`; expect success.
- [ ] **Step 7: Commit.** Commit as `feat: add SuperGrok Responses proxy`.

### Task 5: Add login, image, CI, and bridge documentation

**Files:**
- Create: `../grok-bridge/scripts/login.ts`
- Create: `../grok-bridge/test/login.test.ts`
- Create: `../grok-bridge/Dockerfile`
- Create: `../grok-bridge/.dockerignore`
- Create: `../grok-bridge/.gitlab-ci.yml`
- Create: `../grok-bridge/DESIGN.md`

**Interfaces:**
- Consumes: `GrokOAuthClient.login`, `GrokProxyClient.inspectAccount/discoverModels`, `BaoCredentialStore`, operator `VAULT_ADDR`/`VAULT_TOKEN`.
- Produces: `bun run login`, an amd64 container image, and a GitLab CI image tag keyed by commit SHA.

- [ ] **Step 1: Write the failing login test.** Inject OAuth, account, catalog, and store adapters. Prove unsafe privacy prevents persistence; safe privacy writes exactly one complete credential record; stdout contains only verification URI/code and success state, never token/account payloads.
- [ ] **Step 2: Implement the workstation command.** Require operator OpenBao credentials, perform device login, inspect privacy/catalog, fail closed, and CAS-create/replace the approved path. Do not create a local auth file.
- [ ] **Step 3: Add container packaging.** Use a multi-stage frozen Bun install; copy only runtime files; run as UID/GID 1000 with a read-only-compatible filesystem. CI runs frozen install and `bun run check`, then publishes `$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA` for amd64.
- [ ] **Step 4: Document the runtime contract.** `DESIGN.md` records single tenancy, endpoint set, privacy invariant, OpenBao ownership, eight-model maximum allowlist, no PAYG, source revisions, and operational error boundaries.
- [ ] **Step 5: Run full bridge verification.** Run `nix develop /Users/shdrch/projects/aether --command bun run check`; expect all tests and type checking to pass. Build and smoke-run the container locally; call `/health` and confirm `200`.
- [ ] **Step 6: Commit and publish.** Commit as `build: package SuperGrok bridge`, push the private GitLab repository, wait for successful CI, and resolve the immutable registry digest without exposing registry credentials.

### Task 6: Declare OpenBao and Kubernetes infrastructure

**Files:**
- Create: `tofu/home/kubernetes/grok.tf`
- Modify: `tofu/home/kubernetes/namespace_contracts.tf`
- Modify: `tofu/home/kubernetes/litellm.tf`
- Modify: `Taskfile.yml`

**Interfaces:**
- Consumes: immutable bridge image digest and the existing `kubernetes-aether` auth mount.
- Produces: `grok` namespace, bridge workload/service/route, exact-path OpenBao policy/role, projected token, caller bearer, `GROK_BRIDGE_API_KEY`, and `task grok:login`.

- [ ] **Step 1: Add the namespace contract.** Declare internal hostname `grok.home.shdr.ch`, GitLab registry access, no backup/S3 secret, normal criticality, and allowlisted egress.
- [ ] **Step 2: Declare the credential boundary.** Add random bridge bearer, `grok-bridge` service account, exact OpenBao data/metadata policy, and Kubernetes auth role bound only to that service account and namespace.
- [ ] **Step 3: Declare the workload.** Follow `muse.tf`: one `Recreate` replica, immutable image, non-root/read-only security context, disabled default automount, projected Bao audience token, configuration Secret, registry pull secret, `/health` liveness, `/ready` readiness, service, internal HTTPRoute with `sectionName = "http"`, and CiliumNetworkPolicy.
- [ ] **Step 4: Restrict egress.** Permit DNS, OpenBao, `auth.x.ai`, and `cli-chat-proxy.grok.com` only. Do not permit `api.x.ai`.
- [ ] **Step 5: Wire LiteLLM's bridge bearer.** Add `GROK_BRIDGE_API_KEY` to the LiteLLM environment Secret and Deployment environment using the existing Muse pattern.
- [ ] **Step 6: Add the login task.** Implement `task grok:login` beside `muse:login`, using cached operator OpenBao credentials and `${GROK_BRIDGE_REPO:-../grok-bridge}` without emitting secrets.
- [ ] **Step 7: Validate and plan.** Run `tofu fmt -check`, `tofu validate`, Taskfile parsing, and a targeted plan for Grok prerequisites/workload plus LiteLLM. Require zero destroys and inspect every change.
- [ ] **Step 8: Commit.** Commit as `feat: deploy SuperGrok subscription bridge` without staging unrelated user changes.

### Task 7: Bootstrap the bridge and discover entitlements

**Files:**
- Modify only OpenBao runtime state and generated outputs required by normal Aether workflows; never commit plaintext credentials.

**Interfaces:**
- Consumes: bridge image, Aether declarations, cached operator login, and user device authorization.
- Produces: a ready direct Responses bridge and the exact live `supergrok/*` model set consumed by Task 8.

- [ ] **Step 1: Verify access and cluster target.** Run `task login:status` and require `kubectl config current-context` to equal `admin@aether-k8s`.
- [ ] **Step 2: Apply prerequisites only.** Apply the namespace, service account, OpenBao policy/role, and bridge-bearer resources through saved targeted plans. Never force-unlock state.
- [ ] **Step 3: Authenticate SuperGrok.** Run `task grok:login`, present the device verification URI/code, wait for user authorization, and confirm only that the OpenBao record exists. If privacy is unsafe, stop with the xAI-controlled remediation path; never mutate privacy automatically.
- [ ] **Step 4: Deploy the bridge.** Apply the workload/service/route/policy resources, wait for rollout, and require HTTPRoute `Accepted=True` and `ResolvedRefs=True`.
- [ ] **Step 5: Verify direct behavior.** Confirm `/health`, `/ready`, protected `/v1/models`, unauthenticated `401`, unknown-model rejection, one streaming `/v1/responses` marker, one reasoning response, and one tool-call response.
- [ ] **Step 6: Record the confirmed catalog.** Capture only public model IDs from `/v1/models` for Task 8. Do not print account identity, raw entitlement data, or credentials. Inspect sanitized request metadata or egress evidence to prove `cli-chat-proxy.grok.com` was used and `api.x.ai` was not.
- [ ] **Step 7: Verify usage boundaries.** Call `/usage` without printing identity/raw payloads. Confirm an unavailable usage endpoint does not fail `/ready`.

### Task 8: Add LiteLLM access and verify end to end

**Files:**
- Modify: `tofu/home/kubernetes/litellm_config.yaml.tftpl`
- Modify: `ansible/playbooks/register_litellm_virtual_keys.yml`
- Modify: `docs/ai-ml.md`

**Interfaces:**
- Consumes: the exact live model IDs from Task 7, `https://grok.home.shdr.ch/v1`, and `GROK_BRIDGE_API_KEY`.
- Produces: pinned `supergrok/*` LiteLLM deployments, OMP/Colony authorization, and verified Chat Completions compatibility.

- [ ] **Step 1: Add the LiteLLM credential.** Configure `grok_bridge_credential` with the internal API base and bridge bearer.
- [ ] **Step 2: Add one entry per confirmed model.** Use exact public names from Task 7, OpenAI Responses routing, `use_responses_api: true`, and per-model 660-second stream/request bounds. Do not add `router/grok-*`, aliases, Cursor/OpenRouter fallbacks, or unconfirmed models.
- [ ] **Step 3: Grant client access.** Add confirmed pins to OMP and Colony virtual-key model lists without altering defaults or other aliases.
- [ ] **Step 4: Update Aether documentation.** Record runtime/IaC ownership, `task grok:login`, privacy fail-closed behavior, credential path, model pins, Responses translation boundary, no-PAYG guarantee, and best-effort usage endpoint.
- [ ] **Step 5: Validate rendered configuration.** Run Ansible syntax check, YAML/template parsing, duplicate model-name detection, `tofu fmt -check`, `tofu validate`, and a targeted plan. Require no destroys and no changes to existing Cursor/OpenRouter Grok entries.
- [ ] **Step 6: Commit the integration.** Commit as `feat: expose pinned SuperGrok models` without staging unrelated user changes.
- [ ] **Step 7: Deploy LiteLLM integration.** Apply its Secret/config/Deployment changes from a saved plan, wait for rollout, and run `task configure:litellm-keys`.
- [ ] **Step 8: Verify every confirmed pin.** For each exposed `supergrok/*` model, make a bounded streaming marker request through LiteLLM Chat Completions. Confirm at least one Chat-to-Responses translation, reasoning-item preservation, tool-call preservation, and no automatic Cursor/OpenRouter deployment selection.
- [ ] **Step 9: Verify no fallback path.** Search code and rendered configuration for `api.x.ai`, `XAI_API_KEY`, or fallback credentials; allow only negative tests and explanatory documentation. Exercise an unavailable model/quota response and confirm it cannot select Cursor, OpenRouter, or PAYG.
- [ ] **Step 10: Complete namespace baseline.** Apply the generated External Secrets service account/policy/role/SecretStore for the new namespace and verify it is `Ready=True`.
- [ ] **Step 11: Publish and report.** Push bridge and Aether commits, preserve unrelated local changes, and report image digest, ready resources, models actually exposed, direct/LiteLLM inference evidence, privacy state, subscription-usage evidence, and any unavailable entitlement.
