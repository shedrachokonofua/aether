# =============================================================================
# Orion feed agents (`orion-feed-<topic>`) — one Daimyo agent per Home topic
# =============================================================================
# V2 (2026-10-15): one omp agent per topic via for_each over local.feed_topics,
# each with its own model, schedules, tools (least privilege), prompt and
# budget, sharing the card contract below. Agents read Home's data through
# Orion's own /api/mcp/home (bearer token in OpenBao orgs/personal/orion-home)
# so no per-source egress or grants are needed; web search stays the Deskplane
# `web` grant where listed. Every MCP tool is listed explicitly: scheduled runs
# have no one to answer `ask` approvals, so an unlisted tool would deny.
#
# Model choice: high-frequency/simple topics (homelab, weather, sports, todos,
# gitlab) run on the local aether/qwen3.8-flash-next. llama-swap finding
# (llama_swap.tf): qwen3.8-flash-next is preloaded (ttl 0, pinned resident)
# and shares the `llm` matrix set "(q3827|qfn|q36|g31|g26|q35) & emb &
# (rr|qrr) & asr & tts" with qwen3.8-27b (Beryl) — exactly one chat model is
# resident at a time, so any chat request evicts the other (evict_costs 25/25).
# Running the frequent topics on flash-next does NOT thrash Beryl more than
# Beryl already thrashes flash-next: the set holds one chat model either way,
# and flash-next is the pinned/preloaded default that reloads fastest. The
# 27b is on-demand (since 2026-09-30) precisely so flash-next can be the
# resident. Briefing and news (daily/few-times-daily synthesis) run on
# moira/flash (Ollama Cloud glm-5.3-flash via LiteLLM) or better.
#
# GitLab: no per-agent http/MCP grant. Daimyo task egress already allows
# gitlab.home.shdr.ch FQDNs (daimyo.tf), but an http grant needs a dummy
# secret/header and cannot express GitLab's PRIVATE-TOKEN cleanly; instead
# Orion exposes a `gitlab` home-MCP tool using Orion's own GITLAB_TOKEN
# (Orion pod env, see orion.tf patch notes). Same for todos: the `todos`
# and notes tools on the home MCP read the vault through Orion's
# NotesService — agents never get a notes-MCP grant.
#
# Orion's poller (FEED_OWNER's stored refresh token) ingests succeeded task
# results from every orion-feed-<topic> agent into feed_cards; needsYou cards
# push via ntfy (topic secret in OpenBao orgs/personal/orion-ntfy).
# Quiet hours, mutes, snoozes and votes are enforced/stored Orion-side.

locals {
  # Card output schema, shared by every topic operation. Daimyo validates
  # each result against it; an invalid result fails with reason `schema`.
  feed_card_schema = {
    type                 = "object"
    additionalProperties = false
    required             = ["cards"]
    properties = {
      cards = {
        type     = "array"
        maxItems = 50
        items = {
          type                 = "object"
          additionalProperties = false
          required             = ["key", "topic", "title", "body"]
          properties = {
            key = { type = "string", minLength = 1, maxLength = 200 }
            topic = {
              type = "string"
              enum = ["homelab", "markets", "sports", "news", "weather", "briefing", "thread", "gitlab", "todos", "watch"]
            }
            title    = { type = "string", minLength = 1, maxLength = 120 }
            body     = { type = "string", maxLength = 4000 }
            needsYou = { type = "boolean" }
            priority = { type = "string", enum = ["low", "normal", "high"] }
            actions = {
              type     = "array"
              maxItems = 6
              items = {
                type                 = "object"
                additionalProperties = false
                required             = ["label", "kind"]
                properties = {
                  label  = { type = "string", minLength = 1, maxLength = 120 }
                  kind   = { type = "string", enum = ["open", "ask", "refresh"] }
                  url    = { type = "string", maxLength = 2000 }
                  prompt = { type = "string", minLength = 1, maxLength = 2000 }
                }
              }
            }
            expiresAt = { type = "string", format = "date-time" }
            resolved  = { type = "boolean" }
            watchId   = { type = "string", minLength = 1, maxLength = 200 }
          }
        }
      }
    }
  }

  feed_input_schema = {
    type                 = "object"
    additionalProperties = false
    required             = ["topic", "at"]
    properties = {
      topic = {
        type = "string"
        enum = ["homelab", "markets", "sports", "news", "weather", "briefing", "gitlab", "todos"]
      }
      at = { type = "string", format = "date-time" }
    }
  }

  # The card contract every topic's prompt carries (kept in step with
  # orion src/lib/server/feed/types.ts). Rich cards: a short paragraph plus
  # small orion-chart / orion-table / orion-stat / orion-images /
  # orion-callout fences where useful (docs/agent-response-formats.md).
  feed_card_contract = <<-EOT
    You post cards to Shedrach's Home feed. Return exactly one JSON object:
    {"cards": [Card, ...]} and nothing else.

    First, learn before you post:
    - If a preferences note exists at Feed/Preferences/<your topic>.md, read
      it first with notes_get and follow it (it distils his votes; his edits
      there win).
    - Call feed_feedback for your topic and adapt: do more of what he voted
      up, stop what he voted down, honour his reasons.
    - Call feed_mutes and never post a card matching a mute rule.
    - Call feed_recent and reuse the key of any card you are updating;
      resolve keys whose issues have cleared.

    Card:
    - key: stable identity (e.g. "homelab:backup-age"). A later card with the
      same key replaces the earlier one. One key per watched thing; never post
      near-duplicates under new keys.
    - topic: this run's topic.
    - title: ≤120 characters, the headline finding.
    - body: Markdown ≤4000 characters. A short paragraph of finished findings
      with confidence — never a plan, a question, or "unavailable" when a tool
      errored (retry or try another tool first). Where useful add ONE small
      rich fence: orion-chart (series), orion-table (exact rows), orion-stat
      (headline numbers), orion-callout (a warning). Keep tables ≤10 rows and
      charts ≤24 points in feed cards.
    - needsYou: true only when Shedrach must act. It pushes a phone
      notification (held 22:00–07:00 Toronto unless a homelab cluster-down
      outage). Set it sparingly. Markets cards must never set needsYou.
    - priority: "low" | "normal" | "high".
    - actions: up to 6 of {"label", "kind": "open"|"ask"|"refresh", "url"?,
      "prompt"?}. An "ask" action starts a thread with prompt (e.g.
      "Investigate the failing backup"); "open" needs a url.
    - expiresAt: RFC 3339, when the card stops mattering.
    - resolved: true (with key/title/body) closes the card with that key —
      use it when an issue you reported has cleared, instead of a "fixed" card.
    - watchId: only for topic "watch" (not yours unless instructed).
  EOT

  feed_topic_instructions = {
    homelab  = <<-EOT
      Topic: homelab (every 15 min). Check alerts, metrics, and drill into
      anything off with prometheus_query (failing pods, backups, disk, nodes,
      Ceph). One card per real issue, keyed "homelab:<thing>", needsYou when
      Shedrach must act. For a cluster-down class outage (node down, API down,
      Ceph health error) use priority "high" and a key/title naming the node /
      API / Ceph — those push even in quiet hours. When everything is healthy,
      post one quiet "homelab:status" card (low priority) and resolve any
      issue keys that cleared. A small orion-chart of the offending metric
      helps; keep it to one chart per card.
    EOT
    markets  = <<-EOT
      Topic: markets. Research with finviz first (market overview, sector
      performance, volume/relative-volume movers, market news, then
      fundamentals for names that matter; Shedrach follows NVDA, AAPL, AMZN,
      GOOGL, SHOP), plus stocks for quotes and web search for crypto/FX
      (BTC, XMR, CAD/NGN, USD/NGN) finviz does not cover. One summary card
      "markets:today" synthesizing the mood and the why, with a small
      orion-table of the watchlist moves. Never needsYou.
    EOT
    sports   = <<-EOT
      Topic: sports. Use espn (scoreboard, standings, news). Teams that
      matter: Manchester United, Arsenal, Miami Heat, Toronto Tempo (WNBA),
      plus Lionel Messi (Inter Miami and Argentina matches). One card per
      game involving those teams, keyed "sports:<home>-<away>-<date>":
      a preview before it starts, updated in place while live (same key),
      a final at full time, expiring a few hours after. Other leagues only
      if something big happened. A compact orion-stat score/minute line is
      welcome on live cards.
    EOT
    news     = <<-EOT
      Topic: news. Read news (Miniflux) and web search for the day's several
      notable stories across topics, skipping pure sports/market stories.
      One digest card "news:digest" with why each story matters.
    EOT
    weather  = <<-EOT
      Topic: weather. Use weather for Toronto. One card "weather:toronto"
      with current conditions, today's range, the next days, and anything
      worth planning around (storms, extremes). Quiet unless severe.
    EOT
    briefing = <<-EOT
      Topic: briefing (07:00 daily). Call feed_recent and read the latest
      cards of every topic, then write ONE summary card "briefing:morning":
      what needs Shedrach today first, then the state of the homelab,
      weather, markets, sports, gitlab, todos and news in a sentence each.
      needsYou only if any source card does.
    EOT
    gitlab   = <<-EOT
      Topic: gitlab. Call gitlab: failed pipelines on default branches and
      open merge requests needing Shedrach's review. One card per failed
      pipeline ("gitlab:pipeline:<project>:<ref>") and one summary card
      "gitlab:merge-requests" when MRs wait. needsYou for failed pipelines
      on default branches. Resolve pipeline keys that pass again (check the
      latest pipeline state). A small orion-table of waiting MRs helps.
    EOT
    todos    = <<-EOT
      Topic: todos. Call todos: open items from his Notes vault. Post ONE
      card "todos:today" listing due or overdue items first (with dates and
      source note), then a count of the rest. needsYou only when something
      is overdue. If nothing is due or overdue, post a quiet low-priority
      card with the open count, or no card if nothing is open.
    EOT
  }

  # One agent per topic. Tools are the least each topic needs; every agent
  # also gets feed_feedback/feed_mutes/notes_get/notes_search implicitly via
  # `common_tools` below (training loop + preferences + mutes).
  # budget_usd becomes the task key's LiteLLM max_budget as is (daimyo
  # broker), and a 0 budget is already spent, so local topics get $1: local
  # models cost nothing and the cap only bounds a runaway.
  feed_topics = {
    homelab = {
      model       = "aether/qwen3.8-flash-next"
      budget_usd  = 1
      max_turns   = 40
      home_tools  = ["metrics", "alerts", "quotas", "prometheus_query", "feed_recent"]
      web_tools   = []
      schedules   = [{ name = "homelab", cron = "*/15 * * * *", jitter = "60s" }]
      description = "Homelab health cards for Shedrach's Home feed (every 15 min)."
    }
    briefing = {
      model       = "moira/flash"
      budget_usd  = 5
      max_turns   = 40
      home_tools  = ["feed_recent"]
      web_tools   = []
      schedules   = [{ name = "briefing", cron = "0 7 * * *", jitter = "120s" }]
      description = "07:00 morning briefing card summarising every feed topic."
    }
    news = {
      model       = "moira/flash"
      budget_usd  = 5
      max_turns   = 50
      home_tools  = ["news", "feed_recent"]
      web_tools   = ["search_web", "scrape", "parse_document"]
      schedules   = [{ name = "news", cron = "0 7,12,18 * * *", jitter = "120s" }]
      description = "News digest cards for Shedrach's Home feed."
    }
    markets = {
      model       = "moira/flash"
      budget_usd  = 5
      max_turns   = 60
      home_tools  = ["stocks", "finviz", "feed_recent"]
      web_tools   = ["search_web", "scrape"]
      schedules   = [{ name = "markets", cron = "5 9-16 * * 1-5", jitter = "60s" }]
      description = "Markets summary cards (never needsYou)."
    }
    weather = {
      model       = "aether/qwen3.8-flash-next"
      budget_usd  = 1
      max_turns   = 25
      home_tools  = ["weather", "feed_recent"]
      web_tools   = []
      schedules   = [{ name = "weather", cron = "30 6,12,17 * * *", jitter = "60s" }]
      description = "Toronto weather cards for Shedrach's Home feed."
    }
    sports = {
      model       = "aether/qwen3.8-flash-next"
      budget_usd  = 1
      max_turns   = 40
      home_tools  = ["espn", "feed_recent"]
      web_tools   = []
      schedules   = [{ name = "sports", cron = "*/30 * * * *", jitter = "60s" }]
      description = "Per-game cards: Man Utd, Arsenal, Miami Heat, Toronto Tempo, Messi."
    }
    gitlab = {
      model       = "aether/qwen3.8-flash-next"
      budget_usd  = 1
      max_turns   = 30
      home_tools  = ["gitlab", "feed_recent"]
      web_tools   = []
      schedules   = [{ name = "gitlab", cron = "*/30 * * * *", jitter = "60s" }]
      description = "GitLab failed pipelines and MRs needing Shedrach."
    }
    todos = {
      model      = "aether/qwen3.8-flash-next"
      budget_usd = 1
      max_turns  = 25
      home_tools = ["todos", "feed_recent"]
      web_tools  = []
      schedules = [
        { name = "todos", cron = "0 7,12,18 * * *", jitter = "60s" },
      ]
      description = "Due/overdue todo items from the Notes vault."
    }
  }

  feed_common_home_tools = ["feed_feedback", "feed_mutes", "notes_get", "notes_search"]
}

resource "kubectl_manifest" "daimyo_orion_feed_agent" {
  for_each   = local.feed_topics
  depends_on = [kubectl_manifest.daimyo_project]

  yaml_body = yamlencode({
    apiVersion = "daimyo.shdr.ch/v1alpha1"
    kind       = "Agent"
    metadata = {
      name      = "orion-feed-${each.key}"
      namespace = "org-personal"
      labels    = local.daimyo_cr_labels
    }
    spec = {
      project     = "personal"
      description = each.value.description
      harness = {
        kind = "omp"
        # Must exist in LiteLLM (litellm_config.yaml.tftpl): local flash is
        # llama-swap resident; moira/flash is Ollama Cloud.
        model        = each.value.model
        systemPrompt = join("\n\n", [trimspace(local.feed_card_contract)])
        tools        = { bash = false, files = false, web = false }
        maxTurns     = each.value.max_turns
      }
      resources = { cpu = "1", memory = "2Gi", workspace = "1Gi" }
      operations = [{
        name           = "cards"
        deadline       = "10m"
        inputSchema    = local.feed_input_schema
        outputSchema   = local.feed_card_schema
        promptTemplate = "'You are the ${each.key} feed agent. Scheduled at ' + input.at + '.\\n\\n' + ${jsonencode(local.feed_topic_instructions[each.key])} + '\\n\\n' + ${jsonencode(trimspace(local.feed_card_contract))}"
      }]
      schedules = [
        for s in each.value.schedules : {
          name      = s.name
          cron      = s.cron
          timezone  = "America/Toronto"
          operation = "cards"
          input     = "{\"topic\": \"${each.key}\", \"at\": scheduledAt}"
          overlap   = "skip"
          jitter    = s.jitter
        }
      ]
      grants = concat(
        [
          {
            name  = "models"
            model = { models = [each.value.model], budgetUsd = each.value.budget_usd }
          },
          {
            name = "home"
            mcp = {
              url = "http://orion.${local.orion_ns}.svc:${local.orion_port}/api/mcp/home"
              auth = {
                secret = {
                  secret = { path = "orgs/personal/orion-home", key = "token" }
                  header = { name = "Authorization" }
                  prefix = "Bearer"
                }
              }
              # Every tool listed: scheduled runs cannot answer `ask`.
              tools = concat(each.value.home_tools, local.feed_common_home_tools)
            }
          },
        ],
        length(each.value.web_tools) > 0 ? [{
          name = "web"
          mcp = {
            url = "http://deskplane-mcp.deskplane.svc:8100/mcp"
            auth = {
              secret = {
                secret = { path = "orgs/personal/deskplane", key = "token" }
                header = { name = "Authorization" }
                prefix = "Bearer"
              }
            }
            tools = each.value.web_tools
          }
        }] : []
      )
      endpoints = { stable = { revision = "latest" } }
    }
  })
}

# The v1 single agent (orion-feed) is replaced by the per-topic agents above.
# After this applies, remove any stale `orion-feed` Agent CR if it still
# exists (it was never applied from the v1 patch in most environments; if it
# was, `kubectl -n org-personal delete agent orion-feed`).
