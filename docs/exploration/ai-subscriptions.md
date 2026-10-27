# AI subscriptions for more strong-tier capacity

Researched 2026-10-11. Goal: more capacity in Moira's **strong** band (AA
Intelligence Index 44–49) for omp's agent traffic. Prices and limits come from
vendor pages cited per row; anything a vendor does not publish is marked
**[UNVERIFIED]**. AA scores were read from
<https://artificialanalysis.ai/leaderboards/models> on 2026-10-11.

## Load being sized

LiteLLM spend logs, 24 h to 2026-10-11 18:10 EDT: omp sent **3.0B input
tokens in 17,750 calls (~171k tokens per call)**; everything else together sent
~65M. Agent turns re-send long histories, so cost is dominated by **cached
input**, then fresh input; output is small. Comparisons below assume **90%
cache hits** and quote **$ per 1B input tokens**; "per day" figures use
2.7B cached + 0.3B fresh + 30M output.

Credit plans are converted with real rates, not 1 credit = 1 token. Xiaomi's
rates come from Moira's plan config, calibrated against the Xiaomi console
(`tofu/home/kubernetes/moira/tiers.yaml`): MiMo V2.6 Pro costs **2.5 credits
per cached token, 300 per fresh input token, 600 per output token**, i.e.
~32 credits per input token at 90% cache, ~38 once output (10M per 1B input)
is counted.

## Ranked options

| # | Option | Strong model (AA) | Price | What it buys at this load | ≈ $/1B input | Access | Quota readable |
|---|---|---|---|---|---|---|---|
| 0 | **Score Claude Sonnet 5.5 in Moira** (existing Claude subscription) | Sonnet 5.5: high 46.8, xhigh 51.9, max 56.0 | $0 more | Shares the Claude weekly pool with Opus and Haiku | — | `claude/sonnet-5-5` already routed via claude-bridge | yes (bridge) |
| 1 | **Meta Model API, Contributor tier** (pay per token) | Muse Spark 1.3: xhigh 45 (max 48 may be Standard-only) | $0.10 in / $0.002 cached / $0.20 out per 1M | $41/day for the whole 3B/day; capped at 100 RPM, 3M TPM | ~$14 | OpenAI-compatible `api.meta.ai/v1` | `x-ratelimit-*` headers |
| 2 | **Charm Hyper** | GLM-5.3 45, Qwen3.8 Max 45, Kimi K3 44 | $20/mo = 250 Hypercredits/day ($12.50/day) | ~30M GLM-5.3 tokens/day (~0.9B/mo) | ~$22 | OpenAI + Anthropic API, external clients allowed | `GET /v1/credits`, per-response remaining |
| 3 | **Z.AI GLM Coding Max** (upgrade) | GLM-5.3 max 45 | $168/mo | 28k credits/5h, 140k/week; Z.AI's own 95%-cache estimate 3–6B tokens/mo; 50% credit discount off-peak | $28–56 | existing `zai/` provider | existing poller |
| 4 | **Kilo Pass, annual** | whole strong catalog at list price (MiMo V2.6 Pro $0.43 / $0.0036 / $0.87) | $19 / $49 / $199 per month + 50% bonus credits | pay-per-token at list + bonus | MiMo Pro ~$37 | OpenAI-compatible gateway | per-response usage; balance API [UNVERIFIED] |
| 5 | **Command Code Max 20×** | whole strong catalog at API rates | $200/mo → $300 standard + $200 premium credits; caps $90/5h, $180/week | MiMo Pro: ~5.4B tokens/mo from standard credits | ~$37 | existing `commandcode/` provider | Moira already reads its credits |
| 6 | **MiMo Token Plan Max** (upgrade from annual Lite) | MiMo V2.6 Pro 46 | $100/mo for 82B credits (Pro: $50 for 38B) | ~2.1B tokens/mo at 90% cache, ~3.5B at 95% (output included) | ~$47 (~$29 at 95%) | existing `xiaomi/` provider | Moira local count |
| 7 | **MiMo pay-per-token** | MiMo V2.6 Pro 46 | $0.435 / $0.0036 / $0.87 per 1M | $166/day for the whole 3B/day | ~$55 | existing key | balance only |
| — | StepFun Flash Max | Step 5 Preview 44 | $99/mo for 40B credits | **sold out, every tier**, no restock date | — | — | — |

### 0. Claude Sonnet 5.5 (no purchase)

- AA rows: `Claude Sonnet 5.5 (High, Default Fallback)` 46.75, `(Xhigh, …)`
  51.90, `(Max, …)` 56.00, `(Medium, …)` 40.84
  (<https://artificialanalysis.ai/leaderboards/models>,
  <https://artificialanalysis.ai/models/releases/comparisons/claude-opus-5-5-vs-claude-sonnet-5-5>).
  High lands in strong, xhigh in frontier.
- Moira never scored it: `scripts/refresh-scores.ts` collapses AA's
  `(<Effort>, Default Fallback)` labels into one `default` row (it printed
  `claude-sonnet-5.5: { default: 36 }`).
- Limits: Claude plans have "a weekly usage limit that applies across all
  models" (<https://support.claude.com/en/articles/8325606>,
  <https://support.claude.com/en/articles/11049741>); only Fable has a
  separate cap (<https://support.claude.com/en/articles/11145838>). How fast
  Sonnet draws the pool compared with Opus is **[UNVERIFIED]**: Anthropic says
  only that usage varies by model and effort
  (<https://support.claude.com/en/articles/9797557>). Resellers that meter in
  dollars charge Sonnet 5.5 half of Opus 5.5 ($2/$10 vs $4/$20 per 1M,
  <https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing>).
- Cost: strong traffic on Sonnet competes with Opus, currently the only
  frontier model with quota.

### 1. Meta Model API, Contributor tier

- Prices and limits: <https://dev.meta.ai/docs/pricing-rate-limits> —
  Contributor $0.10 in / $0.20 out / $0.002 cached per 1M, 100 RPM / 3M TPM
  per team; Standard $1.25 / $4.25 / $0.15. Contributor prompts may be used
  for training (the same terms as the Contributor model already in use).
- Different product from the current Muse access: muse-bridge serves the
  **Muse Code subscription** (weekly quota shared by Standard and Contributor;
  `docs/ai-ml.md`). The Model API is billed per token with a separate key,
  so it would be another `router/muse-spark-1.3-contributor` leg.
- `max` effort may be Standard-only (<https://dev.meta.ai/docs/models>;
  **[UNVERIFIED]** for Contributor). Moira's `aa_scores.yaml` scores
  `muse-spark-1.3-contributor` max at 48; if Contributor rejects `max`, that
  entry is wrong.
- 3M TPM ≈ 17 calls/min at 171k tokens; omp averages ~12/min, so parallel
  subagent bursts would hit 429s and fall through to the next candidate.

### 2. Charm Hyper

<https://hyper.charm.land/>, <https://hyper.charm.land/faq>: $20/month gives
250 Hypercredits per day (1 HC = $0.05; unused credits don't carry over).
Live `/v1/models` price for GLM-5.3: $1.524 in, $0.283 cache hit, $4.79 out per
1M; at 90% cache that is $407 per 1B, so $12.50/day buys ~30M tokens/day.
Credits API: <https://hyper.charm.land/docs/api/credits.md>.

### 3. Z.AI GLM Coding Max

<https://z.ai/subscribe>, <https://docs.bigmodel.cn/cn/coding-plan/overview>:
Lite $18 (2k credits/5h, 10k/week), Pro ~$72–80 (12k/60k), Max $168
(28k/140k). Z.AI's own estimate for Max at 95% cache is 676M–1.35B tokens per
week. Off-peak (outside Mon–Fri 14:00–18:00 UTC+8) burns half the credits.

### 4. Kilo Pass

<https://kilo.ai/pricing/kilo-pass>, <https://kilo.ai/docs/gateway>,
<https://kilo.ai/docs/gateway/usage-and-billing>: gateway at
`https://api.kilo.ai/api/gateway` (OpenAI-compatible), inference at upstream
list price, 5% card fee, Pass bonus credits (annual 50%/month) expire each
cycle. Catalog includes every strong model, including MiMo V2.6 Pro at
$0.0036/M cached (<https://api.kilo.ai/api/gateway/models>).

### 5. Command Code Max 20×

<https://commandcode.ai/docs/resources/pricing-limits>,
<https://commandcode.ai/docs/provider>: GOAT $10 → $70 credits, Pro $20 → $80,
Max 10× $100 → $150, Max 20× $200 → $300 standard + $200 premium. Rolling caps
per 5h/week: Max 10× $45/$90, Max 20× $90/$180. Credits are spent at API rates
with no markup. The account currently shows 0 credits (Moira `commandcode`
credits window at 100%).

### 6–7. Xiaomi MiMo

Plans (<https://mimo.mi.com/docs/zh-CN/price/token-plan>): Lite $6 (4.1B
credits/mo), Standard $16 (11B), Pro $50 (38B), Max $100 (82B); no 5-hour
cap; 0.8× credit burn at night (00:00–08:00 Beijing). Pay per token
(<https://mimo.mi.com/docs/en-US/price/pay-as-you-go>): Pro $0.435 /
$0.0036 cached / $0.87 per 1M, cache writes free for a limited time, Batch
50%. The current annual Lite pool (49.2B) is 96% used after five months.
Using a plan key behind a bridge is **[UNVERIFIED]** against Xiaomi's terms.

## Upgrades with unpublished quotas

- **ChatGPT**: `plan_type: prolite` is the $100 Pro tier; Pro 200 adds a
  separate Astra allowance and more Codex use, but OpenAI publishes no
  absolute quotas (<https://help.openai.com/en/articles/9793128>). Moira's
  learned capacity for the current plan was ~80M tokens/week at this load.
- **Claude Max 20×** ($200): 20× Pro per 5-hour session; the weekly pool
  growth over Max 5× is **[UNVERIFIED]**.
- **Muse Code** plans: Everyday, High (5×), Power (20×)
  (<https://dev.meta.ai/docs/muse-code/subscriptions>); current tier and
  prices **[UNVERIFIED]**.
- **SuperGrok Plus/Heavy** ($100 / ~$300 **[UNVERIFIED]**): the only
  economical Grok 4.7 route; quotas unpublished.
- **Gemini 4 Argon** (AA 53, frontier): the current Google AI Pro plan
  already serves it through Antigravity (`antigravity/gemini-4-argon`, since
  2026-10-15) from a separate weekly-only Pro quota. Ultra includes higher
  Argon quota in the larger Gemini pool, according to the quota-summary RPC's
  group description.

## Not worth it for this load

- **Request-capped coding plans** (Volcengine Ark, Alibaba Coding Plan, Baidu):
  top tiers allow ~90k requests/month against ~540k
  (<https://help.aliyun.com/zh/model-studio/coding-plan>).
- **IDE and agent harnesses without a usable API**: Cursor, Windsurf, Factory,
  Amp, Augment, Warp (ToS forbids external use), Zed, JetBrains.
- **GitHub Copilot**: strong models, but only through an undocumented
  internal API.
- **Mistral** (best model AA 38), **MiniMax** (M3 AA 29), **Perplexity**
  subscriptions, **Cerebras** and **Groq** (no strong model).
- **Gemini CLI / Code Assist OAuth**: Google forbids proxying it through
  third-party clients.
- **Claude models through Antigravity**: excluded by the operator.

## Gaps

- Sonnet-versus-Opus burn rate on Claude subscriptions.
- Whether Muse Contributor accepts `max` effort (Model API and Muse Code).
- Muse Code tier currently held, and its upgrade prices.
- Xiaomi and StepFun terms for plan keys behind a proxy.
