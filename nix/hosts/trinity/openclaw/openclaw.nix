# OpenClaw service configuration
# Podman container via quadlet-nix with OpenBao-managed secrets
#
# Secrets flow:
#   OpenBao KV (kv/data/aether/openclaw)
#     → vault-agent renders /run/secrets/openclaw.env
#       → Podman container reads env file
#
# Config flow:
#   Nix-managed /etc/openclaw/openclaw.json
#     → bind-mounted into container as /home/node/.openclaw/openclaw.json
{ config, lib, pkgs, facts, ... }:

{
  # ===========================================================================
  # OpenBao Templates — secrets rendered to /run/secrets/
  # ===========================================================================

  aether.openbao-agent.templates."openclaw.env" = {
    contents = ''
{{ with secret "kv/data/aether/openclaw" }}LITELLM_API_KEY={{ .Data.data.litellm_api_key }}
MATRIX_ACCESS_TOKEN={{ .Data.data.matrix_access_token }}
OPENCLAW_GATEWAY_TOKEN={{ .Data.data.gateway_token }}
OPENROUTER_API_KEY={{ .Data.data.openrouter_api_key }}{{ end }}'';
    perms = "0600";
    restartServices = [ "openclaw.service" ];
  };

  # ===========================================================================
  # Podman Quadlet Container
  # ===========================================================================

  virtualisation.podman.enable = true;

  virtualisation.quadlet.containers.openclaw = {
    autoStart = true;
    containerConfig = {
      image = "ghcr.io/openclaw/openclaw:latest";
      publishPorts = [
        "18789:18789"
      ];
      volumes = [
        "/var/lib/openclaw:/home/node/.openclaw:Z"
        "/var/lib/openclaw/workspace:/home/node/.openclaw/workspace:Z"
        "/etc/openclaw/openclaw.json:/home/node/.openclaw/openclaw.json:ro"
      ];
      environments = {
        NODE_ENV = "production";
      };
      environmentFiles = [
        "/run/secrets/openclaw.env"
      ];
    };
    serviceConfig = {
      Restart = "always";
      RestartSec = "10";

      # Resource limits
      MemoryMax = "3600M";
      CPUQuota = "200%";
      TasksMax = 256;
    };
    unitConfig = {
      Description = "OpenClaw AI Assistant";
      After = [ "vault-agent.service" ];
      Wants = [ "vault-agent.service" ];
    };
  };

  # ===========================================================================
  # OpenClaw Configuration (declarative, managed by Nix)
  # ===========================================================================

  environment.etc."openclaw/openclaw.json".text = builtins.toJSON {
    agents = {
      defaults = {
        model = {
          primary = "litellm/anthropic/claude-opus-4.6";
          fallbacks = [
            "litellm/aether/qwen3:30b"
            "litellm/openai/gpt-4.1"
          ];
        };
      };
    };
    models = {
      mode = "merge";
      providers = {
        litellm = {
          baseUrl = "https://litellm.home.shdr.ch/v1";
          apiKey = "\${LITELLM_API_KEY}";
          api = "openai-completions";
          models = [
            { id = "anthropic/claude-opus-4.6"; name = "Claude Opus 4.6"; }
            { id = "aether/qwen3:30b"; name = "Qwen3 30B"; }
            { id = "openai/gpt-4.1"; name = "GPT 4.1"; }
          ];
        };
      };
    };
    channels = {
      matrix = {
        homeserverUrl = "https://matrix.home.shdr.ch";
        allowFrom = [ "@shdrch:home.shdr.ch" ];
        groups = {
          "*" = { requireMention = true; };
        };
      };
    };
    gateway = {
      port = 18789;
      bind = "lan";
      trustedProxies = [ "10.0.2.2" "10.0.3.1" "127.0.0.1" ];
      auth = {
        token = "\${OPENCLAW_GATEWAY_TOKEN}";
      };
      controlUi = {
        enabled = true;
        allowInsecureAuth = true;
      };
    };
    tools = {
      web = {
        search = {
          enabled = true;
          provider = "perplexity";
          perplexity = {
            apiKey = "\${OPENROUTER_API_KEY}";
            baseUrl = "https://openrouter.ai/api/v1";
            model = "perplexity/sonar-pro";
          };
        };
        fetch = {
          enabled = true;
        };
      };
    };
    session = {
      reset = {
        idleMinutes = 30;
      };
    };
  };

  # ===========================================================================
  # Persistent State
  # ===========================================================================

  systemd.tmpfiles.rules = [
    "d /var/lib/openclaw 0750 1000 1000 -"
    "d /var/lib/openclaw/workspace 0750 1000 1000 -"
    "d /etc/openclaw 0755 root root -"
  ];
}
