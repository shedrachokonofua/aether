# Bastion LXC — break-glass admin host on INFRA (VLAN 2, 10.0.2.10).
# Cert-only SSH (via the lab SSH CA) plus a browser path: Caddy fronts
# oauth2-proxy → termix at https://bastion.home.shdr.ch.
#
# Stay deliberately separate from anything running on k8s so this still works
# when the cluster is on fire.
{ config, lib, pkgs, modulesPath, facts, ... }:

let
  termixImage     = "ghcr.io/lukegus/termix:latest";
  termixPort      = 8080;
  oauth2ProxyPort = 4180;
  publicHost      = "bastion.home.shdr.ch";
  keycloakIssuer  = "https://auth.shdr.ch/realms/aether";
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../../modules/base.nix
    ../../modules/step-ca-cert.nix
    ../../modules/openbao-agent.nix
  ];

  networking.hostName = "bastion";

  # step-ca cert is bootstrapped at LXC provisioning time (Ansible pct push);
  # this module just keeps it renewed and bounces vault-agent on rotation.
  aether.step-ca-cert = {
    enable = true;
    onRenew = [ "vault-agent.service" ];
  };

  # Pull oauth2-proxy secrets from kv/data/aether/bastion (written by tofu in
  # tofu/home/bastion.tf). Rendered to /run/secrets/oauth2-proxy.env which the
  # oauth2-proxy systemd unit consumes via EnvironmentFile.
  aether.openbao-agent = {
    enable = true;
    templates."oauth2-proxy.env" = {
      contents = ''
        OAUTH2_PROXY_CLIENT_SECRET={{ with secret "kv/data/aether/bastion" }}{{ .Data.data.oauth2_proxy_client_secret }}{{ end }}
        OAUTH2_PROXY_COOKIE_SECRET={{ with secret "kv/data/aether/bastion" }}{{ .Data.data.oauth2_proxy_cookie_secret }}{{ end }}
      '';
      perms = "0400";
      user  = "oauth2-proxy";
      group = "oauth2-proxy";
      restartServices = [ "oauth2-proxy.service" ];
    };
  };

  # Lab toolchain — mirrors the dev shell so admin work on this box matches
  # what `nix develop` gives us on the laptop.
  environment.systemPackages = with pkgs; [
    opentofu
    ansible
    python3Packages.ansible-pylibssh
    sops
    age
    openbao
    step-cli
    awscli2
    rclone
    kubectl
    talosctl
    cilium-cli
    istioctl
    kubernetes-helm
    glab
    podman
    git
    jq
    yq-go
    curl
    unzip
    openssh
    direnv
    nix-direnv
    tmux
    ripgrep
    fd
    bat
    eza
    htop
    btop
    go-task
  ];

  programs.bash.interactiveShellInit = ''
    eval "$(${pkgs.direnv}/bin/direnv hook bash)"
  '';

  # Container runtime for termix. Podman matches the read-only-root posture
  # better than Docker on an unprivileged LXC.
  virtualisation = {
    podman = {
      enable = true;
      dockerSocket.enable = false;
      defaultNetwork.settings.dns_enabled = true;
    };
    oci-containers = {
      backend = "podman";
      containers.termix = {
        image = termixImage;
        ports = [ "127.0.0.1:${toString termixPort}:8080" ];
        environment = {
          NODE_ENV = "production";
        };
        volumes = [
          "/var/lib/termix:/app/data"
        ];
        extraOptions = [ "--pull=always" ];
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/termix 0750 root root -"
  ];

  # OAuth2-proxy in front of termix. Public TLS terminates at the home gateway
  # (Caddy on home_gateway_stack); the gateway forwards plaintext over the lab
  # network to oauth2-proxy here. So oauth2-proxy listens on the LAN
  # interface, but the firewall only admits the gateway.
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    clientID = "bastion";
    clientSecret = null;  # comes from EnvironmentFile
    cookie.secret = null; # comes from EnvironmentFile
    email.domains = [ "*" ];
    oidcIssuerUrl = keycloakIssuer;
    redirectURL = "https://${publicHost}/oauth2/callback";
    httpAddress = "0.0.0.0:${toString oauth2ProxyPort}";
    upstream = [ "http://127.0.0.1:${toString termixPort}/" ];
    setXauthrequest = true;
    reverseProxy = true;
    extraConfig = {
      cookie-secure = "true";
      cookie-domain = publicHost;
      # Distinct cookie name so it doesn't collide with the gateway's
      # `_oauth2_proxy` cookie (gateway scopes to .shdr.ch, which the
      # browser also sends to bastion.home.shdr.ch — same name with
      # different signing secret confuses both proxies).
      cookie-name = "_bastion_oauth2_proxy";
      whitelist-domain = publicHost;
      allowed-role = "admin";
      pass-access-token = "true";
      pass-authorization-header = "true";
    };
  };

  systemd.services.oauth2-proxy = {
    after  = [ "vault-agent.service" ];
    wants  = [ "vault-agent.service" ];
    serviceConfig.EnvironmentFile = "/run/secrets/oauth2-proxy.env";
  };

  # Firewall: SSH for break-glass; oauth2-proxy reachable from INFRA only.
  # Bastion lives on VLAN 2; the gateway (10.0.2.2) is the only intended
  # consumer of 4180, but constraining further requires iptables extraCommands
  # rather than nftables-style rules. Lab-network exposure is acceptable.
  networking.firewall.allowedTCPPorts = [ 22 oauth2ProxyPort ];

  aether.otel-agent.prometheusScrapeConfigs = [
    { job_name = "oauth2-proxy"; targets = [ "127.0.0.1:${toString oauth2ProxyPort}" ]; }
  ];
}
