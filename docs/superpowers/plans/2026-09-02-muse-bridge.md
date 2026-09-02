# Muse Subscription Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a private Muse Code subscription bridge behind LiteLLM and replace Muse Spark 1.2 routing with separate normal and Contributor 1.3 streaming pools.

**Architecture:** A dedicated Bun bridge performs Meta device OAuth, stores rotating credentials in a single OpenBao KV v2 record, and proxies one allowlisted OpenAI-compatible model. Aether deploys the bridge and joins it with Command Code/Clinepass in the normal pool while keeping Contributor-only providers in a separate pool.

**Tech Stack:** Bun 1.3.14, TypeScript, `bun:test`, Meta OAuth/Model API, OpenBao KV v2 and Kubernetes auth, OpenTofu, Kubernetes, LiteLLM, Ansible, GitLab CI.

**Spec:** `docs/superpowers/specs/2026-09-02-muse-bridge-design.md`

## Global Constraints

- Pin OAuth behavior to OMP PR #10498 head `d51f6b0293b3c7ce299eb921b5846aaa45663e73` and retain source attribution.
- Subscription only; never load or fall back to a PAYG Meta API key.
- Keep normal and Contributor deployments in disjoint routing groups.
- Router contract is `stream: true`; provider pins document protocol limitations.
- Persist rotated OAuth and minted API-key state at OpenBao logical path `aether/muse-bridge/credentials` using KV v2 CAS.
- Never print credentials or store them in repository plaintext.
- Run every repository command through Aether's Nix development shell.
- Deploy only through declared Aether IaC; no live patching.

---

### Task 1: Bootstrap the bridge and OAuth module

**Files:**
- Create: `../muse-bridge/package.json`
- Create: `../muse-bridge/tsconfig.json`
- Create: `../muse-bridge/src/oauth.ts`
- Create: `../muse-bridge/src/types.ts`
- Create: `../muse-bridge/test/oauth.test.ts`

**Interfaces:**
- Produces: `MuseCredentials`, `MuseOAuthClient.login(onAuth, signal)`, and `MuseOAuthClient.refresh(credentials, signal)`.
- Consumes: Meta device/token/key endpoints fixed in the approved spec.

- [ ] Write tests for trusted device URLs, pending/slow-down polling, missing intervals, inactive subscriptions, token refresh, rotated refresh tokens, and minted API keys.
- [ ] Run `nix develop /Users/shdrch/projects/aether --command bun test test/oauth.test.ts`; expect failures because the module is absent.
- [ ] Implement strict response parsing, bounded requests, device polling, key minting, login, and refresh. Include an attribution comment naming PR #10498 and commit `d51f6b0`.

```ts
export interface MuseCredentials {
  schemaVersion: 1;
  access: string;
  refresh: string;
  expires: number;
  apiKey: string;
  accountId?: string;
  email?: string;
}

export class MuseOAuthClient {
  login(onAuth: (url: string, code: string) => void, signal?: AbortSignal): Promise<MuseCredentials>;
  refresh(credentials: MuseCredentials, signal?: AbortSignal): Promise<MuseCredentials>;
}
```

- [ ] Re-run the focused test and type check; expect success.
- [ ] Commit as `feat: add Muse subscription OAuth flow`.

### Task 2: Add OpenBao credential persistence

**Files:**
- Create: `../muse-bridge/src/bao.ts`
- Create: `../muse-bridge/src/credentials.ts`
- Create: `../muse-bridge/test/bao.test.ts`
- Create: `../muse-bridge/test/credentials.test.ts`

**Interfaces:**
- Consumes: `MuseCredentials`, `MuseOAuthClient.refresh`.
- Produces: `TokenProvider`, `BaoCredentialStore.read/write`, and `MuseCredentialManager.currentApiKey/refreshAfterUnauthorized/ready`.

```ts
export interface VersionedCredentials {
  version: number;
  credentials: MuseCredentials;
}

export interface TokenProvider {
  token(signal?: AbortSignal): Promise<string>;
}

export class BaoCredentialStore {
  read(signal?: AbortSignal): Promise<VersionedCredentials>;
  write(credentials: MuseCredentials, expectedVersion: number, signal?: AbortSignal): Promise<number>;
}

export class MuseCredentialManager {
  initialize(signal?: AbortSignal): Promise<void>;
  ready(): boolean;
  currentApiKey(signal?: AbortSignal): Promise<string>;
  refreshAfterUnauthorized(failedKey: string, signal?: AbortSignal): Promise<string>;
}
```

- [ ] Write failing tests for Kubernetes auth, exact KV paths, KV v2 response parsing, CAS writes, conflicts, single-flight refresh, write-before-adopt, and stale-key `401` races.
- [ ] Run focused tests and confirm the expected failures.
- [ ] Implement static operator-token and Kubernetes-auth token providers, the KV store, CAS conflict handling, and the credential manager.
- [ ] Re-run focused tests and type checking; expect success.
- [ ] Commit as `feat: persist Muse credentials in OpenBao`.

### Task 3: Add the authenticated OpenAI proxy

**Files:**
- Create: `../muse-bridge/src/server.ts`
- Create: `../muse-bridge/src/index.ts`
- Create: `../muse-bridge/test/server.test.ts`

**Interfaces:**
- Consumes: `MuseCredentialManager`.
- Produces: `createHandler(deps): (request: Request) => Promise<Response>` and the Bun process entry point.

```ts
export interface ServerDependencies {
  credentials: MuseCredentialManager;
  bridgeApiKey: string;
  fetchImpl?: typeof fetch;
  upstreamUrl?: string;
}

export function createHandler(
  dependencies: ServerDependencies,
): (request: Request) => Promise<Response>;
```

- [ ] Write failing tests for `/health`, `/ready`, bearer authentication, static catalog, model allowlisting, model rewrite, header stripping, JSON relay, SSE relay/cancellation, one-time `401` refresh, and non-retry behavior for `402`, `403`, `429`, `5xx`, and network failures.
- [ ] Run the server test and confirm expected failures.
- [ ] Implement the minimal handler. Use `crypto.timingSafeEqual`; never log request bodies or auth headers. Preserve only safe upstream response headers such as content type, request ID, retry-after, and cache controls.
- [ ] Add startup configuration for `PORT`, `BRIDGE_API_KEY`, `BAO_ADDR`, `BAO_AUTH_PATH`, `BAO_ROLE`, `BAO_KV_MOUNT`, `BAO_SECRET_PATH`, and projected JWT path.
- [ ] Re-run tests and type checking; expect success.
- [ ] Commit as `feat: add Muse OpenAI proxy`.

### Task 4: Add login, image, CI, and operator documentation

**Files:**
- Create: `../muse-bridge/scripts/login.ts`
- Create: `../muse-bridge/Dockerfile`
- Create: `../muse-bridge/.dockerignore`
- Create: `../muse-bridge/.gitignore`
- Create: `../muse-bridge/.gitlab-ci.yml`
- Create: `../muse-bridge/DESIGN.md`

**Interfaces:**
- Consumes: `MuseOAuthClient.login`, `BaoCredentialStore`, operator `VAULT_ADDR`/`VAULT_TOKEN`.
- Produces: `bun run login`, amd64 container image, GitLab checks/build.

- [ ] Add a login test that injects OAuth and store adapters and proves credentials are written without being printed.
- [ ] Implement the workstation command so it prints only verification URI/code and a success message.
- [ ] Add a multi-stage Bun image running as UID/GID 1000 and a GitLab pipeline that runs frozen install, typecheck/tests, then publishes `$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA`.
- [ ] Run `nix develop /Users/shdrch/projects/aether --command bun run check`; expect all tests to pass.
- [ ] Commit as `build: package Muse bridge`.
- [ ] Push the repository, wait for the image tag, and resolve its immutable registry digest.

### Task 5: Declare OpenBao and Kubernetes infrastructure

**Files:**
- Create: `tofu/home/kubernetes/muse.tf`
- Modify: `tofu/home/kubernetes/namespace_contracts.tf`
- Modify: `tofu/home/kubernetes/litellm.tf`
- Modify: `Taskfile.yml`

**Interfaces:**
- Consumes: immutable bridge image digest and current `kubernetes-aether` auth mount.
- Produces: `muse` namespace, bridge deployment/service/route, exact-path OpenBao policy/role, projected token, caller bearer, and `task muse:login`.

- [ ] Add the `muse` namespace contract with GitLab registry access, allowlisted egress, and internal hostname `muse.home.shdr.ch`.
- [ ] Declare a bridge-only OpenBao policy for exact data/metadata paths and a Kubernetes role bound to the `muse-bridge` service account and existing OpenBao audience.
- [ ] Declare registry and bridge environment Secrets, one-replica `Recreate` deployment, explicit projected audience token, `/health` liveness, `/ready` readiness, service, and internal HTTPRoute.
- [ ] Add `MUSE_BRIDGE_API_KEY` to LiteLLM's environment secret and container environment.
- [ ] Add `task muse:login` to run the bridge login utility with cached operator Bao credentials and write directly to the approved path.
- [ ] Run `tofu fmt -check` and a targeted `task tofu:plan`; require no destroys.
- [ ] Commit as `feat: deploy Muse subscription bridge`.

### Task 6: Replace Muse 1.2 with separate 1.3 routers

**Files:**
- Modify: `tofu/home/kubernetes/litellm_config.yaml.tftpl`
- Modify: `ansible/playbooks/register_litellm_virtual_keys.yml`
- Modify: `docs/ai-ml.md`

**Interfaces:**
- Consumes: `https://muse.home.shdr.ch/v1` and `MUSE_BRIDGE_API_KEY`.
- Produces: provider pins, two disjoint routing groups, aliases, and OMP/Colony access.

- [ ] Add `muse_bridge_credential` and the `muse-subscription/muse-spark-1.3` deployment.
- [ ] Add Command Code and Clinepass normal 1.3 pins/deployments under `router/muse-spark-1.3`.
- [ ] Add Command Code, Clinepass, and OpenCode Go Contributor pins/deployments under `router/muse-spark-1.3-contributor`.
- [ ] Add latency routing groups and aliases for `muse-spark-1.3` and `muse-spark-1.3-contributor`.
- [ ] Remove every 1.2 Contributor deployment, group, alias, allowlist entry, and documentation reference.
- [ ] Grant OMP and Colony both groups, aliases, and all six provider pins. Document `stream: true` and public-work-only Contributor semantics.
- [ ] Run Ansible syntax check, template checks, `tofu fmt -check`, and a targeted plan with no destroys.
- [ ] Commit as `feat: split Muse 1.3 routing pools`.

### Task 7: Bootstrap, deploy, and verify

**Files:**
- Modify only generated/encrypted credential state required by `task muse:login`; never commit plaintext.

**Interfaces:**
- Consumes: bridge image, Aether declarations, operator browser approval.
- Produces: live bridge and LiteLLM routes.

- [ ] Apply only Muse OpenBao/Kubernetes prerequisites through `task tofu:apply`.
- [ ] Run `task muse:login`; complete Meta device authorization and confirm the OpenBao record exists without reading its value.
- [ ] Confirm the bridge rollout, `/health`, `/ready`, protected model catalog, JSON completion, and SSE completion.
- [ ] Apply the LiteLLM secret/deployment changes and run `task configure:litellm-keys`.
- [ ] Verify all six provider pins with their supported protocols.
- [ ] Verify `router/muse-spark-1.3` and `router/muse-spark-1.3-contributor` using streaming calls and LiteLLM deployment metadata; confirm no cross-group deployment.
- [ ] Verify a subscription quota failure cannot select PAYG.
- [ ] Push Aether commits while preserving unrelated user changes in `secrets/secrets.yml`, `composer.tf`, and `litellm.tf` unless a directly required hunk is intentionally included.
