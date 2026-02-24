# OpenClaw Exploration

Self-hosted personal AI assistant with multi-channel messaging, agent runtime, and tool execution.

## Goal

Deploy a conversational AI assistant that:

1. Lives entirely on the homelab — no cloud dependency for the runtime
2. Integrates with existing LLM infrastructure (LiteLLM → Opus 4.6, local models)
3. Reachable via Matrix (and selectively via WhatsApp/GMessages bridges)
4. Has tool/agent capabilities (browser, shell, files) in a sandboxed environment
5. Follows existing NixOS patterns (declarative, reproducible, secrets via OpenBao)

## Current State

| Aspect       | Current                           | Gap                                        |
| ------------ | --------------------------------- | ------------------------------------------ |
| AI Chat      | OpenWebUI, LibreChat (web only)   | No conversational agent in messaging apps  |
| LLM Access   | LiteLLM gateway (Claude, Ollama)  | No agent runtime consuming these models    |
| Matrix       | Synapse + bridges (WhatsApp, SMS) | No AI bot in the homeserver                |
| Tool Use     | Manual via IDE (Cursor, etc.)     | No autonomous agent with tool access       |

## What is OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) is an open-source, self-hosted AI assistant built on Node.js. Key features:

- **Gateway architecture** — WebSocket server on port 18789, single process
- **Multi-channel** — WhatsApp, Telegram, Slack, Discord, Matrix, WebChat, and more
- **Agent runtime** — Tool execution (browser automation, shell, file operations)
- **Model agnostic** — OpenAI-compatible API support (works with LiteLLM)
- **Docker/Podman support** — Official container image at `ghcr.io/openclaw/openclaw`
- **Nix support** — `nix-openclaw` flake available

## Proposed Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                    OpenClaw Stack (NixOS LXC · V3 Services)                  │
│                                                                              │
│   ┌──────────────────────────────────────────────────────────────────────┐   │
│   │                      NixOS LXC Container                             │   │
│   │                      2 vCPU, 2GB RAM, 20GB disk                      │   │
│   │                                                                      │   │
│   │   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐        │   │
│   │   │   Podman      │     │  vault-agent │     │  step-ca     │        │   │
│   │   │  (OpenClaw)   │     │  (secrets)   │     │  (cert renew)│        │   │
│   │   │  :18789       │     │  /run/secrets│     │  mTLS auth   │        │   │
│   │   └──────┬───────┘     └──────────────┘     └──────────────┘        │   │
│   │          │                                                           │   │
│   └──────────┼───────────────────────────────────────────────────────────┘   │
│              │                                                               │
│              │  Connections (all within V3 Services VLAN 10.0.3.0/24):      │
│              │                                                               │
│              ├──► LiteLLM (litellm.home.shdr.ch)     — LLM inference        │
│              ├──► Synapse (matrix.home.shdr.ch)       — Matrix channel       │
│              └──► OpenBao (openbao.home.shdr.ch)      — Secrets (mTLS)      │
│                                                                              │
│   External access:                                                           │
│              Caddy ──► openclaw.home.shdr.ch ──► :18789 (WebChat)           │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Networking

OpenClaw drops into the existing V3 Services VLAN with zero new firewall rules.

### Traffic Flows

| Flow | Source | Destination | Port | Notes |
| --- | --- | --- | --- | --- |
| LLM inference | OpenClaw | LiteLLM | 443 (HTTPS) | Via `litellm.home.shdr.ch` |
| Matrix messages | OpenClaw | Synapse | 443 (HTTPS) | Via `matrix.home.shdr.ch` |
| Secrets (mTLS) | OpenClaw | OpenBao | 8200 | Internal, cert auth |
| WebChat UI | Caddy | OpenClaw | 18789 | Reverse proxy |
| Cert renewal | OpenClaw | step-ca | 443 | Auto-renewal daemon |

All of these are intra-VLAN or already-permitted flows. No VyOS firewall changes needed.

### DNS & Reverse Proxy

Single Caddy entry on the Gateway Stack:

```caddyfile
openclaw.home.shdr.ch {
    forward_auth keycloak:8080 {
        uri /realms/home/protocol/openid-connect/auth
        # existing Keycloak forward auth config
    }
    reverse_proxy <openclaw-lxc-ip>:18789
}
```

The `*.home.shdr.ch` wildcard DNS rewrite already resolves to the Gateway IP. Caddy auto-provisions a step-ca TLS certificate. Keycloak forward auth protects the WebChat UI.

## Model Access

OpenClaw connects to the existing LiteLLM gateway as a single OpenAI-compatible endpoint.

### Configuration

```json
{
  "models": {
    "provider": "custom",
    "custom": {
      "baseUrl": "https://litellm.home.shdr.ch/v1"
    }
  },
  "agent": {
    "model": "anthropic/claude-opus-4.6",
    "fallbackModels": [
      "aether/qwen3:30b",
      "openai/gpt-5.2"
    ]
  }
}
```

### LiteLLM Virtual Key

Create a dedicated virtual key for OpenClaw in LiteLLM with:

- **Budget cap** — Monthly spend limit to prevent runaway agent loops
- **Model allowlist** — Restrict to approved models only
- **Rate limits** — RPM/TPM caps appropriate for personal use
- **Logging** — All requests tagged with `user: openclaw` for audit

The virtual key is stored in OpenBao at `kv/data/aether/openclaw`.

## Channel Strategy

### Safety Ranking

| Channel | Safety | Why |
| --- | --- | --- |
| **WebChat** | Highest | Keycloak SSO + gateway token. Only you can talk to it. |
| **Matrix (DM)** | High | Token auth + `allowFrom` whitelist. Direct, no injection surface. |
| **Matrix (room)** | Medium | `requireMention: true` limits activation. Other users could attempt prompt injection. |
| **WhatsApp/SMS (via bridge)** | Lower | External messages flow through mautrix bridges. Injection risk from incoming messages. |

### Recommended Setup

**Primary:** WebChat (daily use, full trust)

**Secondary:** Matrix DM with strict allowlist:

```json
{
  "channels": {
    "matrix": {
      "homeserverUrl": "https://matrix.home.shdr.ch",
      "allowFrom": ["@you:home.shdr.ch"],
      "groups": {
        "*": { "requireMention": true }
      }
    }
  }
}
```

**Optional (with caution):** Selective bridge access via a dedicated Matrix room:

1. Create a private Matrix room (e.g., `#ai-assistant:home.shdr.ch`)
2. Invite OpenClaw bot + the bridge bot (mautrix-whatsapp)
3. Bridge only that room to a specific WhatsApp contact/group
4. Set `requireMention: true` so OpenClaw only responds when @mentioned
5. Keep OpenClaw out of your main bridged rooms

This gives you the ability to talk to OpenClaw from WhatsApp without exposing it to all incoming messages from every contact.

## Secrets Management

Uses the OpenBao agent pattern — same as the blockchain stack. No sops-nix.

### Secret Flow

```
cloud-init provisions machine cert
        │
        ▼
step-ca-cert-renew (daemon, auto-renews cert)
        │ on renewal, restarts ▼
vault-agent (authenticates via cert, renders /run/secrets/openclaw.env)
        │ on secret change, restarts ▼
openclaw.service (reads env file, connects to LiteLLM + Matrix)
```

### OpenBao KV Layout

```
kv/data/aether/openclaw
  ├── litellm_api_key      — LiteLLM virtual key for budget/rate limiting
  ├── matrix_access_token   — Synapse bot account token
  └── gateway_token         — WebSocket gateway auth token
```

### OpenBao Policy

```hcl
# policy: openclaw
path "kv/data/aether/openclaw" {
  capabilities = ["read"]
}

path "kv/data/aether/openclaw/*" {
  capabilities = ["read"]
}
```

### vault-agent Template

```nix
aether.openbao-agent.templates = {
  "openclaw.env" = {
    contents = ''
      {{ with secret "kv/data/aether/openclaw" }}LITELLM_API_KEY={{ .Data.data.litellm_api_key }}
      MATRIX_ACCESS_TOKEN={{ .Data.data.matrix_access_token }}
      OPENCLAW_GATEWAY_TOKEN={{ .Data.data.gateway_token }}{{ end }}
    '';
    perms = "0600";
    restartServices = [ "openclaw.service" ];
  };
};
```

Rotation is zero-downtime: update the secret in OpenBao, vault-agent re-renders within ~1 minute, service restarts automatically. No git commit, no nixos-rebuild, no SSH.

## Isolation & Resource Limits

No Docker sandboxing needed. The LXC itself is the sandbox. Defense in depth via two layers:

### Layer 1: Proxmox LXC Limits

| Resource | Limit | Rationale |
| --- | --- | --- |
| RAM | 2048 MB | Node.js + agent tools headroom |
| Swap | 512 MB | Soft landing, not a crutch |
| vCPU | 2 cores | Enough for agent + tool execution |
| Disk | 20 GB | OpenClaw is stateless-ish, workspace is small |
| CPU weight | 100 (default 1024) | Deprioritised vs. critical services |
| Unprivileged | Yes | No host UID mapping |

### Layer 2: NixOS systemd Hardening

```nix
serviceConfig = {
  # Resource caps
  MemoryMax = "1800M";
  CPUQuota = "200%";        # 2 cores max
  TasksMax = 256;

  # Filesystem isolation
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;

  # Privilege restrictions
  NoNewPrivileges = true;
  RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
};
```

### Why Not Docker Sandboxing

OpenClaw supports Docker-based tool sandboxing (running agent tools inside throwaway containers). This is useful when OpenClaw runs on a shared machine. In an isolated LXC:

- The LXC **is** the sandbox — compromised container can't escape to the host
- Proxmox cgroups enforce hard limits regardless of what happens inside
- systemd hardening adds process-level restrictions
- Nested container runtimes add complexity with marginal security gain
- Performance overhead of Docker-in-LXC is unnecessary

If agent tool execution needs tighter isolation later (e.g., running untrusted code), revisit with Podman-in-Podman or a dedicated sidecar.

## NixOS Configuration

### File Layout

```
nix/hosts/<host>/openclaw/
  ├── default.nix      # Main config: imports, firewall, OTEL, packages
  └── openclaw.nix     # OpenClaw service: quadlet container, openbao templates, config
```

### Skeleton (`default.nix`)

```nix
{ config, lib, pkgs, modulesPath, facts, ... }:

{
  imports = [
    ../../../modules/lxc-hardware.nix    # or vm-hardware.nix
    ../../../modules/lxc-common.nix
    ../../../modules/base.nix
    ../../../modules/step-ca-cert.nix
    ../../../modules/openbao-agent.nix
    ./openclaw.nix
  ];

  # step-ca certificate auto-renewal (machine auth to OpenBao)
  aether.step-ca-cert = {
    enable = true;
    onRenew = [ "vault-agent.service" ];
  };

  # OpenBao agent for secrets
  aether.openbao-agent.enable = true;

  # Firewall — Gateway WebSocket port only
  networking.firewall.allowedTCPPorts = [ 18789 ];

  # OTEL metrics
  aether.otel-agent.prometheusScrapeConfigs = [
    { job_name = "openclaw"; targets = [ "localhost:18789" ]; }
  ];
}
```

### Service (`openclaw.nix`)

```nix
{ config, lib, pkgs, ... }:

{
  # OpenBao templates
  aether.openbao-agent.templates = {
    "openclaw.env" = {
      contents = ''
        {{ with secret "kv/data/aether/openclaw" }}LITELLM_API_KEY={{ .Data.data.litellm_api_key }}
        MATRIX_ACCESS_TOKEN={{ .Data.data.matrix_access_token }}
        OPENCLAW_GATEWAY_TOKEN={{ .Data.data.gateway_token }}{{ end }}
      '';
      perms = "0600";
      restartServices = [ "openclaw.service" ];
    };
  };

  # OpenClaw via quadlet-nix (declarative Podman systemd unit)
  virtualisation.quadlet.containers.openclaw = {
    containerConfig = {
      image = "ghcr.io/openclaw/openclaw:latest";
      publishPorts = [ "18789:18789" ];
      volumes = [
        "/var/lib/openclaw:/home/node/.openclaw:Z"
        "/var/lib/openclaw/workspace:/home/node/.openclaw/workspace:Z"
      ];
      environments = {
        NODE_ENV = "production";
        OPENCLAW_GATEWAY_BIND = "0.0.0.0";
      };
      environmentFiles = [
        "/run/secrets/openclaw.env"
      ];
    };
    serviceConfig = {
      Restart = "always";

      # Hardening
      MemoryMax = "1800M";
      CPUQuota = "200%";
      TasksMax = 256;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # Ensure OpenClaw waits for secrets
  systemd.services.openclaw = {
    after = [ "vault-agent.service" ];
    wants = [ "vault-agent.service" ];
  };

  # OpenClaw config file (declarative, managed by Nix)
  environment.etc."openclaw/openclaw.json".text = builtins.toJSON {
    agent = {
      model = "anthropic/claude-opus-4.6";
      fallbackModels = [
        "aether/qwen3:30b"
        "openai/gpt-5.2"
      ];
    };
    models = {
      provider = "custom";
      custom = {
        baseUrl = "https://litellm.home.shdr.ch/v1";
      };
    };
    channels = {
      matrix = {
        homeserverUrl = "https://matrix.home.shdr.ch";
        allowFrom = [ "@you:home.shdr.ch" ];
        groups = {
          "*" = { requireMention = true; };
        };
      };
    };
    gateway = {
      bind = "0.0.0.0";
      port = 18789;
    };
  };

  # Persistent state directory
  systemd.tmpfiles.rules = [
    "d /var/lib/openclaw 0750 root root -"
    "d /var/lib/openclaw/workspace 0750 root root -"
  ];
}
```

## MCP Tools Integration

OpenClaw's agent runtime will be extended with MCP tool servers via a linked `mcporter` skill. This enables the agent to use tools like:

- Grafana MCP (query Prometheus/Loki, manage dashboards)
- Firecrawl (web scraping)
- Custom MCP servers as needed

MCP server configuration will be added to the OpenClaw config after the base deployment is stable.

## Resource Requirements

| Component | vCPU | RAM | Disk | Notes |
| --- | --- | --- | --- | --- |
| OpenClaw (Podman) | 1-2 | 1-1.5GB | 5GB | Node.js runtime + workspace |
| vault-agent | - | ~50MB | - | Sidecar, minimal |
| step-ca renewal | - | ~10MB | - | Daemon, minimal |
| OS + OTEL | - | ~200MB | 5GB | NixOS base |
| **Total** | **2** | **~2GB** | **~20GB** | |

Lightweight. Comparable to AdGuard LXC, much smaller than the blockchain stack.

## Deployment Plan

### Phase 1: Infrastructure

1. Add LXC definition to `config/vm.yml` (ID TBD, V3 Services VLAN, 2 vCPU, 2GB RAM, 20GB disk)
2. Create OpenTofu resource in `tofu/home/openclaw.tf` (Proxmox LXC + HA)
3. Create NixOS config at `nix/hosts/<host>/openclaw/`
4. Add to `flake.nix` nixosConfigurations
5. Create OpenBao policy and secrets path

### Phase 2: Secrets & Auth

1. Store secrets in OpenBao: `bao kv put kv/aether/openclaw litellm_api_key=... matrix_access_token=... gateway_token=...`
2. Create OpenBao policy (`openclaw`) scoped to `kv/data/aether/openclaw`
3. Bind policy to cert auth role
4. Create LiteLLM virtual key with budget cap and model allowlist
5. Create Matrix bot account on Synapse

### Phase 3: Deploy

1. Apply Tofu: `task tofu:apply`
2. Deploy NixOS: `nixos-rebuild switch --target-host openclaw --impure`
3. Verify vault-agent renders secrets to `/run/secrets/openclaw.env`
4. Verify OpenClaw container starts and connects to LiteLLM
5. Add Caddy reverse proxy entry with Keycloak forward auth

### Phase 4: Channels

1. Test WebChat via `openclaw.home.shdr.ch`
2. Configure Matrix DM channel, verify `allowFrom` whitelist works
3. (Optional) Set up selective bridge room for WhatsApp access
4. Test agent tool execution within the sandboxed environment

### Phase 5: MCP Tools

1. Link mcporter skill for MCP server configuration
2. Add Grafana MCP, Firecrawl, and other tool servers
3. Test agent tool use end-to-end
4. Tune model fallback chain and budget caps based on usage

## Decision Factors

### Pros

- Full control — runs on your hardware, no cloud dependency for the runtime
- Model flexibility — LiteLLM gives access to local and cloud models with a single config
- Existing infra — drops into V3 VLAN, Caddy, Matrix, OpenBao with minimal new config
- NixOS — declarative, reproducible, atomic rollback if anything breaks
- Secret rotation — OpenBao agent auto-picks up changes, no redeployment needed
- Lightweight — 2 vCPU, 2GB RAM, trivial compared to existing workloads

### Cons

- Prompt injection risk — any externally-sourced messages (bridges) are an attack surface
- Agent tool use — shell/browser access requires trust in the model's judgment
- Container image — upstream dependency on `ghcr.io/openclaw/openclaw`
- Early project — OpenClaw is relatively new, API surface may change

### Mitigations

| Risk | Mitigation |
| --- | --- |
| Prompt injection | WebChat primary, Matrix DM with allowlist, bridges only in isolated rooms |
| Agent tool abuse | systemd hardening, Proxmox cgroup limits, restricted filesystem |
| Runaway spend | LiteLLM virtual key with budget cap and rate limits |
| Upstream breakage | Pin container image tag, NixOS rollback if update breaks |

## Open Questions

1. Which Proxmox host for the LXC? (any node with Ceph, HA-eligible)
2. Exact Matrix bot username? (`@openclaw:home.shdr.ch`?)
3. LiteLLM budget cap amount? (start with ~$50/month?)
4. MCP tool servers to enable at launch?
5. Pin OpenClaw to a specific version tag or track latest?

## Reference Links

### OpenClaw Project

| Resource | URL |
| --- | --- |
| GitHub repo | <https://github.com/openclaw/openclaw> |
| Website | <https://openclaw.ai> |
| Docs index | <https://docs.openclaw.ai> |
| DeepWiki (AI-generated code docs) | <https://deepwiki.com/openclaw/openclaw> |
| Discord community | <https://discord.gg/clawd> |
| Changelog | <https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md> |
| ClawHub (skills registry) | <https://clawhub.com> |

### Install & Deployment

| Resource | URL |
| --- | --- |
| Getting started guide | <https://docs.openclaw.ai/start/getting-started> |
| Onboarding wizard | <https://docs.openclaw.ai/start/wizard> |
| Docker install | <https://docs.openclaw.ai/install/docker> |
| Nix flake (`nix-openclaw`) | <https://github.com/openclaw/nix-openclaw> |
| Updating guide | <https://docs.openclaw.ai/install/updating> |
| Development channels (stable/beta/dev) | <https://docs.openclaw.ai/install/development-channels> |
| Linux platform guide | <https://docs.openclaw.ai/platforms/linux> |
| Dockerfile | <https://github.com/openclaw/openclaw/blob/main/Dockerfile> |
| docker-compose.yml | <https://github.com/openclaw/openclaw/blob/main/docker-compose.yml> |
| .env.example | <https://github.com/openclaw/openclaw/blob/main/.env.example> |

### Configuration

| Resource | URL |
| --- | --- |
| Full config reference (all keys) | <https://docs.openclaw.ai/gateway/configuration> |
| Models (selection + auth) | <https://docs.openclaw.ai/concepts/models> |
| Model failover (OAuth vs API keys) | <https://docs.openclaw.ai/concepts/model-failover> |
| Security guide | <https://docs.openclaw.ai/gateway/security> |
| Sandbox config | <https://docs.openclaw.ai/gateway/configuration> |

### Channels (relevant to our setup)

| Resource | URL |
| --- | --- |
| Channels overview | <https://docs.openclaw.ai/channels> |
| Matrix (extension channel) | <https://docs.openclaw.ai/channels/matrix> |
| WebChat | <https://docs.openclaw.ai/web/webchat> |
| WhatsApp (Baileys) | <https://docs.openclaw.ai/channels/whatsapp> |
| Telegram (grammY) | <https://docs.openclaw.ai/channels/telegram> |
| Group messages / routing | <https://docs.openclaw.ai/concepts/group-messages> |
| Channel routing | <https://docs.openclaw.ai/concepts/channel-routing> |
| Troubleshooting | <https://docs.openclaw.ai/channels/troubleshooting> |

### Architecture & Concepts

| Resource | URL |
| --- | --- |
| Architecture overview | <https://docs.openclaw.ai/concepts/architecture> |
| Gateway (control plane) | <https://docs.openclaw.ai/gateway> |
| Agent loop | <https://docs.openclaw.ai/concepts/agent-loop> |
| Session model | <https://docs.openclaw.ai/concepts/session> |
| Multi-agent routing | <https://docs.openclaw.ai/gateway/configuration> |
| Streaming / chunking | <https://docs.openclaw.ai/concepts/streaming> |
| Session pruning | <https://docs.openclaw.ai/concepts/session-pruning> |

### Tools & Skills

| Resource | URL |
| --- | --- |
| Tools overview | <https://docs.openclaw.ai/tools> |
| Browser control | <https://docs.openclaw.ai/tools/browser> |
| Skills platform | <https://docs.openclaw.ai/tools/skills> |
| Skills config | <https://docs.openclaw.ai/tools/skills-config> |
| Cron jobs | <https://docs.openclaw.ai/automation/cron-jobs> |
| Webhooks | <https://docs.openclaw.ai/automation/webhook> |
| Session tools (agent-to-agent) | <https://docs.openclaw.ai/concepts/session-tool> |

### Ops & Networking

| Resource | URL |
| --- | --- |
| Tailscale Serve/Funnel | <https://docs.openclaw.ai/gateway/tailscale> |
| Remote access (SSH tunnels) | <https://docs.openclaw.ai/gateway/remote> |
| Health checks | <https://docs.openclaw.ai/gateway/health> |
| Doctor (diagnostics) | <https://docs.openclaw.ai/gateway/doctor> |
| Logging | <https://docs.openclaw.ai/logging> |
| Control UI | <https://docs.openclaw.ai/web/control-ui> |
| Dashboard | <https://docs.openclaw.ai/web/dashboard> |
| Background process | <https://docs.openclaw.ai/gateway/background-process> |
| Browser troubleshooting (Linux) | <https://docs.openclaw.ai/tools/browser-linux-troubleshooting> |

### Source Code (key files for implementer)

| File | URL |
| --- | --- |
| `openclaw.mjs` (entry point) | <https://github.com/openclaw/openclaw/blob/main/openclaw.mjs> |
| `package.json` | <https://github.com/openclaw/openclaw/blob/main/package.json> |
| `Dockerfile` | <https://github.com/openclaw/openclaw/blob/main/Dockerfile> |
| `Dockerfile.sandbox` | <https://github.com/openclaw/openclaw/blob/main/Dockerfile.sandbox> |
| `docker-compose.yml` | <https://github.com/openclaw/openclaw/blob/main/docker-compose.yml> |
| `SECURITY.md` | <https://github.com/openclaw/openclaw/blob/main/SECURITY.md> |
| `AGENTS.md` (default agent prompt) | <https://github.com/openclaw/openclaw/blob/main/AGENTS.md> |
| `extensions/` (Matrix, Teams, etc.) | <https://github.com/openclaw/openclaw/tree/main/extensions> |
| `skills/` (built-in skills) | <https://github.com/openclaw/openclaw/tree/main/skills> |

## Status

**Exploration complete. Ready for implementation.**

## Related Documents

- `../ai-ml.md` — LiteLLM gateway, Ollama, existing AI stack
- `../communication.md` — Matrix homeserver, Synapse, bridges
- `../networking.md` — VLAN layout, Caddy reverse proxy, DNS
- `../nixos.md` — NixOS migration patterns, quadlet-nix, sops-nix
- `../secrets.md` — OpenBao, vault-agent, cert auth
- `web3.md` — Blockchain stack (same NixOS + OpenBao pattern)
