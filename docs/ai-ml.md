# AI/ML

GPU-accelerated inference runs on **Talos Kubernetes**. Most shared AI workloads, including SnapOtter's file-processing AI tools, use `talos-neo` (RTX Pro 6000 Blackwell).

## Kubernetes GPU stack

| Workload    | Role                                      | Terraform / notes |
| ----------- | ----------------------------------------- | ----------------- |
| llama-swap  | Local GGUF inference (`aether/*` models)  | `tofu/home/kubernetes/llama_swap.tf` |
| ComfyUI     | Stable Diffusion workflows                | `tofu/home/kubernetes/comfyui.tf` |
| Docling     | Document parsing for RAG                  | `tofu/home/kubernetes/docling.tf` |
| JupyterLab  | Notebooks (OpenWebUI code execution)      | `tofu/home/kubernetes/jupyter.tf` |
| Speech      | STT/TTS (Qwen3-ASR + Qwen3-TTS via audio.cpp under llama-swap) | `tofu/home/kubernetes/llama_swap.tf` |
| OpenWebUI   | Chat UI                                   | `tofu/home/kubernetes/openwebui.tf` |
| SnapOtter   | File-processing AI tools                  | `tofu/home/kubernetes/snapotter.tf` |

Model weights and ComfyUI state live on the **local NVMe** PV mounted on `talos-neo` (`gpu_model_storage.tf`).
`llama-swap`, ComfyUI, Docling, and JupyterLab are explicitly pinned to `talos-neo`
with `local.gpu_neo_node_selector`; they still require the NVIDIA Talos
extension selector in addition to the hostname.

Speech (STT/TTS) is served by `audiocpp_server` spawned as llama-swap child
processes: an init container copies the official audio.cpp image's binaries
onto the GPU PV, GGUF packages live under `llama-swap/models/audiocpp/models/`,
and TTS voices are wav + transcript pairs in `.../audiocpp/voices/` selected via
the OpenAI `voice` field. The former Speaches deployment is decommissioned.

SnapOtter uses a Ceph RBD PVC for app data and its AI cache, requests one `nvidia.com/gpu`, uses the `nvidia` runtime class, and pins to `talos-neo` with `local.snapotter_gpu_node_selector`. `SNAPOTTER_GPU=true` keeps rembg/ONNX background-removal models on CUDA; the older `talos-smith` GTX 1660 Super placement could not reliably run the BiRefNet ONNX models through CUDA.

Image generation features (SDXL, Flux, Qwen-Image, ControlNet, LoRAs, etc.) follow upstream ComfyUI; manage models on the GPU PV / ComfyUI paths.

**Not migrated to K8s in-repo:** SwarmUI and ClearML previously ran on the GPU VM; Caddy routes for those hostnames were removed. Re-introduce them when/if you deploy replacements.

## AI Tool Stack (K8s)

LiteLLM, chat, search, crawl, and GPU services are reached via the cluster Gateway. The old **ai-tool-stack** VM has been removed.

| Component | Purpose                           |
| --------- | --------------------------------- |
| LiteLLM   | LLM gateway and proxy             |
| OpenWebUI | Chat UI (K8s)                     |
| SearXNG   | Metasearch (K8s)                  |
| Firecrawl | Crawl + MCP (K8s)                 |

### LiteLLM

Unified OpenAI-compatible API: local models via **llama-swap**, embeddings +
reranker on the same credential, cloud providers, and MCP tools.

**Maintenance hold (2026-09-24):** The model retirements, alias removal,
SuperGrok upgrade, and Cursor integration removal are staged changes.
Their rollout and virtual-key synchronization have not been performed;
do not apply them during server maintenance.

Cursor/Composer is no longer registered with LiteLLM: its model entry,
`composer_credential`, `CURSOR_BRIDGE_API_KEY` injection, and model permissions
have been removed. The standalone Composer deployment and its own credentials
remain declared in [`composer.tf`](../tofu/home/kubernetes/composer.tf).
It still exposes Grok 4.6 over Cursor's native HTTP/2 transport for direct
clients; this change neither upgrades nor decommissions that service.

Qwen Cloud provides the standalone `qwen-cloud/qwen3.8-max` and
`qwen-cloud/qwen3.8-flash` models through Alibaba MaaS. Inquest is configured
to send Holmes investigations to the local `aether/qwen3.8-27b:think`.

Step Plan exposes only `step/step-5-preview` through the OpenAI-compatible
`https://api.stepfun.ai/step_plan/v1` endpoint. The credential is stored as
`litellm.step_api_key` in SOPS and injected as `STEP_API_KEY`. OMP and Colony
virtual keys can select this model; their defaults are unchanged. The route
has no PAYG or OpenRouter fallback.

ChatGPT subscription OAuth uses LiteLLM's native `chatgpt/` provider. Run
`nix develop --command task litellm:login:chatgpt` and complete the displayed
OpenAI device authorization. The dedicated `litellm-chatgpt-auth` Ceph RBD PVC
stores `/var/lib/litellm/chatgpt/auth.json`; LiteLLM updates it during token
refresh. The login task restricts the directory to `0700` and the file to
`0600`. Use a dedicated LiteLLM login rather than sharing a rotating refresh
token with desktop Codex or OMP. Direct OpenAI API-key access is no longer
configured in LiteLLM.

The subscription routes are `chatgpt/gpt-6-astra`, `chatgpt/gpt-6-sol`, and
`chatgpt/gpt-6-luna`, available to OMP and Colony without changing their
defaults. They declare Responses mode and native streaming explicitly because
LiteLLM 1.99.1 does not include GPT-6 in its bundled model catalog.

OpenWebUI's single household model is `router/family` ("Family Assistant"), a
LiteLLM priority pool: GPT-6 Astra on the ChatGPT subscription (`order: 1`),
Muse Spark 1.3 on the subscription bridge and Command Code (`order: 2`), then
MiMo V2.6 Pro on the Xiaomi token plan (`order: 3`). `DEFAULT_MODELS` points
OpenWebUI at it, and it is the only model entry non-admin users can read. The
fallbacks were chosen from the family's own prompts (447 unique, March to
September 2026: study and homework 31%, writing 28%, health 12%; 41% where a
wrong answer could cause harm; 8% need images and 13% documents), so every leg
reads images. On 2026-09-25 the ChatGPT plan hit its weekly usage limit
(`usage_limit_reached`, resetting about 2026-10-02); the `seven30-foundry` key
drove about 84% of that day's ChatGPT-route tokens, so the household pool now
falls through to Muse instead of failing.

Muse reasons privately for up to about 50 seconds before its first token, and
Meta redacts that reasoning on Chat Completions for external keys. The family
pool's Muse legs therefore call Meta's Responses API (`openai/responses/…`)
with `reasoning.summary: concise`; LiteLLM streams the summary as
`reasoning_content`, which OpenWebUI shows as a thinking block. Measured on
2026-09-26, a 250-word explanation showed its summary at 6.8 s and its answer
at 23.7 s. Colony and the other Muse routes stay on Chat Completions.

Use `stream: true` with these routes and list-form `input` for `/v1/responses`.
All three passed streaming Responses inference; streaming Chat Completions
also passed. Non-streaming Chat Completions failed verification with the
bundled adapter (`Unknown items in responses API response: []`). No paid
API-key or OpenRouter fallback is configured.

Clinepass also exposes `clinepass/qwen3.8-max`, `clinepass/muse-spark-1.3`,
and `clinepass/muse-spark-1.3-contributor` as standalone provider pins.

Google Antigravity is exposed through the single-tenant bridge as
`antigravity/gemini-3.8-flash`. The bridge translates OpenAI chat-completions
requests to the subscription API; clients retain ownership of tool execution
and follow-up results. OMP and Colony virtual keys include this model. Colony
uses it in the developer and architect fallback chains, not as a primary.

SuperGrok is exposed only as the subscription-backed
`supergrok/grok-4.7` pin. Stock LiteLLM uses the bridge's
`/v1/chat/completions` endpoint; the bridge translates native Responses
events and preserves tool calls and terminal failures. Native `/v1/responses`
remains available. Neither path falls back to `api.x.ai`, a PAYG key, Cursor,
or OpenRouter. Readiness fails closed unless live xAI metadata confirms Grok
Code access, coding-data retention opt-out or ZDR, and the reviewed model.
Run `task grok:login` to authorize the account and write rotating credentials
to `kv/aether/grok-bridge/credentials` in OpenBao. Runtime infrastructure is
owned by [`tofu/home/kubernetes/grok.tf`](../tofu/home/kubernetes/grok.tf);
bridge source is the private `so/grok-bridge` GitLab project. `/usage` is
best-effort and is not a readiness gate.

Only standard Grok 4.7 is approved; retired 4.6, Fast variants, and unknown
model IDs are rejected. A cached 4.6-only credential catalog cannot mark the
upgraded bridge ready: fresh account and catalog checks must approve 4.7.
The subscription selector is `grok-4.7`; native Responses reported
`grok-4.7-build` during verification, not a separate client-selectable model.
Bounded streaming Chat, a forced function-call/result round trip, and native
Responses passed against the real subscription using the upgraded local
bridge. Credentials were updated only in an isolated in-memory store;
no deployed bridge or OpenBao credential was changed by those checks.

The private Muse bridge exchanges the operator's Muse Code account grant for
the subscription-backed key and exposes `meta/muse-spark-1.3` on both
`/v1/chat/completions` and `/v1/responses`.
Rotated OAuth and subscription credentials persist in a dedicated OpenBao
record; the bridge never falls back to a PAYG Meta key.

`router/glm-5.3` uses weighted shuffle across Z.AI and Ollama Cloud with
weights 4:1. Holmes primary and Hermes Tungsten use this canonical group.
`router/glm-5.3-flash` is a separate pool across Z.AI, Command Code,
OpenCode Go, and Ollama Cloud. Provider-prefixed Flash pins remain standalone,
including the Clinepass pin; Clinepass is not a pool member.

Other multi-provider pools are `router/muse-spark-1.3`,
`router/muse-spark-1.3-contributor`, and `router/hy4-preview`. The normal Muse
pool uses Command Code and the private subscription. The Contributor pool
uses Command Code and also includes the private standard Muse model; it is
not a Contributor-only pool. OpenCode Go is not a Contributor leg: its Muse
Contributor endpoint answered "Endpoint is unavailable" (region-limited per
OpenCode's docs, 2026-09-25). Both Muse routers require streaming. Hy4 pools
Command Code and OpenCode Go.

`router/deepseek-v4-pro` and `router/minimax-m3` each have one Ollama Cloud
backend. Their `router/*` names remain canonical.

`router/mimo-v2.6-pro` and `router/mimo-v2.6-flash` are priority pools, not
shuffles: the Xiaomi MiMo token-plan leg (`order: 1`,
`https://token-plan-sgp.xiaomimimo.com/v1`, SOPS `litellm.xiaomi_api_key`)
takes every request while healthy, and the Command Code and OpenCode Go legs
(`order: 2`) serve only while Xiaomi is failing or cooling down. The
`xiaomi/*`, `commandcode/*`, and `opencode-go/*` MiMo pins stay addressable.
Clinepass also lists MiMo 2.6 but is not wired: it answers
`insufficient_credits` (2026-09-25).

The CodeBuddy international route is pinned as `codebuddy/hy4-preview` rather
than added to the router pool: its endpoint accepts only streaming requests
whose first message is `system`. Colony's Pi transport satisfies both constraints.
OpenCode Go provides `opencode-go/glm-5.3-flash`, `opencode-go/hy4-preview`,
and the `opencode-go/mimo-v2.6-*` pins through `https://opencode.ai/zen/go/v1`. Go
rejects requests without `x-opencode-session` (`MissingSessionID`), so every
OpenCode Go deployment sends a static `x-opencode-session: aether-litellm` and
`User-Agent: aether-litellm/1.0` via `extra_headers`; all gateway traffic shares
that one session.
Kimi is exposed only as `kimi/k3`. Router defaults use a 120-second upstream
timeout for agentic turns, three retries, and one failed deployment before a
300-second cooldown; detailed debug mode is disabled.

The gateway declares 60 unique model names and no `model_group_alias` redirects.
Clients must send an exact `model_name`: use `router/*` for a routing group
or a provider-specific pin to choose that provider deliberately. All 13
compatibility aliases were removed; the Holmes, OMP, and Colony key allowlists
use canonical model names.
Upstream `litellm_params.model` identifiers and Colony's client-local model
labels are not gateway aliases.

The declared retirement removes Kimi K2.x, pre-5.3 GLM, DeepSeek V4 Flash,
MiMo V2.5 Pro, pre-3.8 Gemini chat models, direct OpenAI API-key models, and
all OpenRouter model routes and their retired aliases. DeepSeek V4 Pro
remains; no V4.1 route is configured. The OpenRouter API key stays encrypted
in SOPS but is no longer injected into LiteLLM. The OpenAI provider key was
removed from SOPS and the LiteLLM Secret/environment declarations.

All 19 `aether/*` routes matched llama-swap's advertised catalog in the
pre-maintenance inventory on 2026-09-24, so none was removed. Unloaded
on-demand models were retained; their cached weight files were not all
verified. `gemini-embedding-001` and `text-embedding-3-large` remain local Qwen
embedding compatibility IDs, not Gemini/OpenAI cloud integrations.

Colony's production and example configs are owned by sibling `so/colony`.
Its role chains were re-picked on 2026-09-25 from Colony's run history (45
days to 2026-09-09), AA Intelligence Index v4.3.2 (plus AA-LCR where exposed),
and a 98-session role-suitability run through LiteLLM that submitted via
Colony's real envelope validators with the steer-then-force finalizer:

| Role | Lead | Fallbacks, in order |
| --- | --- | --- |
| architect | Muse Spark Contributor | GLM 5.3, Grok 4.7, Kimi K3, MiMo 2.6 Pro, DeepSeek V4 Pro |
| plan reviewer | GPT-6 Astra | Grok 4.7, Kimi K3, GLM 5.3, MiMo 2.6 Pro, Step 5 Preview |
| code reviewer | Grok 4.7 | Kimi K3, GLM 5.3, MiMo 2.6 Pro, DeepSeek V4 Pro, Muse Spark 1.3 |
| developer | Muse Spark Contributor | MiMo 2.6 Pro, Gemini 3.8 Flash, GLM 5.3 Flash, DeepSeek V4 Pro |

No Muse model reviews plans because Muse writes them, and Muse Spark 1.3 is the
last code-review fallback because Muse writes the code. Qwen 3.8 Max (9-11
minute sessions, rejects a forced `tool_choice`), Qwen 3.8 Flash (0/2 as
developer), and Hy4 (no longer free; its launch promotion ended) left Colony.
Models with good Artificial Analysis unit economics get four concurrent runs
once their pool passes a burst of six concurrent agent turns without errors:
MiMo 2.6 Pro ($0.13 per AA Intelligence Index task, all on the Xiaomi priority
leg), GLM 5.3 Flash ($0.25), DeepSeek V4 Pro ($0.67), Step 5 ($0.72), and
Muse Contributor ($0.10/$0.20 per million tokens on Command Code). Grok 4.7
keeps four on its flat subscription; Kimi K3 and GLM 5.3 stay at two for their
weekly usage windows, and Gemini 3.8 Flash at two. Astra shares the household ChatGPT
subscription behind OpenWebUI, so Colony caps it at one run with an
operational 272,000-token context cap because the subscription route's limit is
unverified. MiMo and Step do not honour a named forced `tool_choice`, so their
Colony entries set `supportsForcedToolChoice: false` and finalizers steer them;
Step also carries a 32,768-token output cap against its verbose prose reasoning.
Muse Spark's 33-49 s first-token wait on open-ended prose is hidden reasoning
(4.7k-9.9k unstreamed reasoning tokens) on every leg, including the subscription
bridge; its agent-shaped tool turns at `xhigh` answer in 1.2-2.8 s.
The configuration is baked into Colony's image, so editing the source YAML
alone does not update a running daemon.

A verified `linux/amd64` SuperGrok bridge image is published under
`source-grok47-20260925` and pinned by digest in
[`grok.tf`](../tofu/home/kubernetes/grok.tf). Colony runs the CI-built image
of `so/colony` commit `b010fca`, pinned by digest in
[`colony.tf`](../tofu/home/kubernetes/colony.tf). Three rollouts on 2026-09-25
(14:01Z, 14:22Z, 14:35Z) ran during planning scopes: the new daemon adopted
and resumed three in-flight architect runs (audit `run.adopted`) but
crash-reaped a fourth, which restarted from scratch; in-flight plan reviews
were reaped and requeued within two seconds. Adoption is not guaranteed.

After maintenance, quiesce Colony scopes and coordinate the updated SuperGrok
and Colony images, LiteLLM configuration, virtual-key synchronization,
Holmes/Kestra model changes, and OpenWebUI catalog refresh before resuming
traffic. Update saved client selections that still use removed aliases or
the retired SuperGrok 4.6 name; no compatibility redirects are configured.

```mermaid
flowchart LR
    subgraph Consumers
        OWUI[OpenWebUI]
        API[API Clients]
    end

    LLM[LiteLLM]

    subgraph K8s["Kubernetes (talos-neo)"]
        LS[llama-swap<br/><i>aether/*</i>]
        RR[Rerank / embed]
    end

    subgraph Cloud["Cloud Providers"]
        OAI[ChatGPT OAuth]
        ZAI[Z.AI]
        QWEN[Qwen Cloud]
        OCGO[OpenCode Go]
        STEP[Step Plan]
    end

    subgraph MCP["MCP Tools"]
        TIME[Time]
        FC[Firecrawl]
        GMAPS[Google Maps]
        TMDB[TMDB]
    end

    OWUI & API --> LLM
    LLM --> LS & RR
    LLM --> OAI & ZAI & QWEN & OCGO & STEP
    LLM --> TIME & FC & GMAPS & TMDB

    style K8s fill:#d4f0e7,stroke:#6ac4a0
    style Cloud fill:#f0e4d4,stroke:#c4a06a
```

See [`tofu/home/kubernetes/litellm_config.yaml.tftpl`](../tofu/home/kubernetes/litellm_config.yaml.tftpl) for the declared model list and MCP registry. Google Maps MCP is opt-in: when `google.project_id` exists in SOPS, [`tofu/google/main.tf`](../tofu/google/main.tf) provisions the Google Maps API key, keeps it in Terraform state, restricts it to Maps APIs, and passes it to the LiteLLM sidecar as `GOOGLE_MAPS_API_KEY`. Google Cloud admin access is keyless after bootstrap: the first apply uses a human Application Default Credential from `gcloud auth application-default login`, then `task login` writes Workload Identity Federation external-account credentials for future OpenTofu runs instead of using a service-account JSON key.

MCP tool calls get LiteLLM's default 60 s cap (`LITELLM_MCP_CLIENT_TIMEOUT`). An overrun returns HTTP 504, which closes the caller's whole MCP session, so a registry entry can raise its own cap with `timeout`; Firecrawl has 110 s. The Seven30 Foundry virtual key (`seven30-foundry`) was created through the LiteLLM API and is not managed in this repo. Since 2026-09-26 its `object_permission.mcp_servers` limits it to Firecrawl and Finviz.

### OpenWebUI

Configured in [`tofu/home/kubernetes/openwebui.tf`](../tofu/home/kubernetes/openwebui.tf): LiteLLM backend, RAG (Docling + reranker URLs), SearXNG, Jupyter, OAuth via Keycloak.

Pinned to `v0.11.4`. Its pod-template annotation hashes LiteLLM's model
configuration; include the OpenWebUI deployment when applying model-route
changes so its startup catalog refreshes through IaC rather than an
imperative restart.

### Access (via Caddy on gateway)

- LiteLLM: `https://litellm.home.shdr.ch`
- OpenWebUI: `https://openwebui.home.shdr.ch`
- llama-swap (OpenAI-compatible): `https://llama-swap.apps.home.shdr.ch`
- ComfyUI: `https://comfyui.home.shdr.ch`
- Docling: `https://docling.home.shdr.ch`
- Jupyter: `https://jupyter.home.shdr.ch`

## Reranker and embeddings

Cross-encoder reranking and Qwen3 embeddings are served through **llama-swap** on the cluster (same `llama_swap_credential` as chat models in LiteLLM), not a separate TEI VM.
