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
  caddyHost       = "bastion.home.shdr.ch";
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

  # OAuth2-proxy in front of termix. Secrets injected via EnvironmentFile
  # rendered by the openbao-agent template above.
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    clientID = "bastion";
    clientSecret = null;  # comes from EnvironmentFile
    cookie.secret = null; # comes from EnvironmentFile
    email.domains = [ "*" ];
    oidcIssuerUrl = keycloakIssuer;
    redirectURL = "https://${caddyHost}/oauth2/callback";
    httpAddress = "127.0.0.1:${toString oauth2ProxyPort}";
    upstream = [ "http://127.0.0.1:${toString termixPort}/" ];
    setXauthrequest = true;
    reverseProxy = true;
    extraConfig = {
      cookie-secure = "true";
      cookie-domain = caddyHost;
      whitelist-domain = caddyHost;
      allowed-role = "bastion:user";
      pass-access-token = "true";
      pass-authorization-header = "true";
    };
  };

  systemd.services.oauth2-proxy = {
    after  = [ "vault-agent.service" ];
    wants  = [ "vault-agent.service" ];
    serviceConfig.EnvironmentFile = "/run/secrets/oauth2-proxy.env";
  };

  # Caddy terminates TLS in front of oauth2-proxy.
  # First boot uses Caddy's internal CA so the box is reachable; once
  # bastion.home.shdr.ch resolves and the lab step-ca cert renewer is in
  # place, swap to a step-ca-issued cert via tls /etc/ssl/...
  services.caddy = {
    enable = true;
    virtualHosts."${caddyHost}" = {
      extraConfig = ''
        tls internal
        encode zstd gzip
        reverse_proxy 127.0.0.1:${toString oauth2ProxyPort} {
          header_up X-Real-IP {http.request.remote}
          header_up X-Forwarded-For {http.request.remote}
          header_up X-Forwarded-Proto {http.request.scheme}
          flush_interval -1
        }
      '';
    };
  };

  networking.firewall.allowedTCPPorts = [ 22 443 ];

  aether.otel-agent.prometheusScrapeConfigs = [
    { job_name = "oauth2-proxy"; targets = [ "127.0.0.1:4180" ]; }
    { job_name = "caddy";        targets = [ "127.0.0.1:2019" ]; }
  ];
}
