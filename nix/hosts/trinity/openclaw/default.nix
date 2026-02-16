# OpenClaw VM configuration
# Self-hosted AI assistant with Matrix integration and WebChat UI
#
# Deployment:
#   1. Apply Tofu to provision VM: task tofu:apply -- -target=proxmox_virtual_environment_vm.openclaw
#   2. Deploy NixOS: task configure:openclaw
#   3. Store secrets: bao kv put kv/aether/openclaw litellm_api_key=... matrix_access_token=... gateway_token=...
#   4. Verify: journalctl -u openclaw -f
{ config, lib, pkgs, modulesPath, facts, ... }:

{
  imports = [
    ../../../modules/vm-hardware.nix
    ../../../modules/vm-common.nix
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

  # OpenBao agent for secrets (API keys, tokens)
  aether.openbao-agent.enable = true;

  # Firewall — Gateway WebSocket port only
  networking.firewall = let
    ports = facts.vm.openclaw.ports;
  in {
    enable = true;
    allowedTCPPorts = [
      ports.gateway  # 18789 - WebChat + API
    ];
  };

  # OTEL metrics collection
  aether.otel-agent.prometheusScrapeConfigs = [
    { job_name = "openclaw"; targets = [ "localhost:${toString facts.vm.openclaw.ports.gateway}" ]; }
  ];
}
