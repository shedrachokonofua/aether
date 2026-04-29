# Admin jump LXC — break-glass admin host on INFRA (VLAN 2, 10.0.2.10).
# Cert-only SSH (via the lab SSH CA) plus a browser path: Caddy fronts
# oauth2-proxy → termix at https://admin.home.shdr.ch.
#
# Stay deliberately separate from anything running on k8s so this still works
# when the cluster is on fire.
{ config, lib, pkgs, modulesPath, facts, ... }:

let
  # Termix — self-hosted SSH terminal manager, run as a container.
  # Pin a digest once you've verified the build you want.
  termixImage = "ghcr.io/lukegus/termix:latest";
  termixPort  = 8080;

  oauth2ProxyPort = 4180;
  caddyHost       = "admin.home.shdr.ch";

  keycloakIssuer  = "https://auth.shdr.ch/realms/aether";
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../../modules/base.nix
    ../../modules/sops.nix
  ];

  networking.hostName = "admin-jump";

  # Lab toolchain. Mirrors the dev shell so admin work on this box matches
  # what we get from `nix develop` on the laptop.
  environment.systemPackages = with pkgs; [
    # IaC
    opentofu
    ansible
    python3Packages.ansible-pylibssh

    # Secrets / certs
    sops
    age
    openbao
    step-cli

    # Cloud / storage
    awscli2
    rclone

    # Kubernetes / Talos
    kubectl
    talosctl
    cilium-cli
    istioctl
    kubernetes-helm

    # GitLab
    glab

    # Containers (for ad-hoc work, not termix's runtime)
    podman

    # Utilities
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

  # Quality-of-life on the shell: nix-direnv hooks for matching the laptop.
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
        # Bind to localhost only — Caddy + oauth2-proxy are the public surface.
        ports = [ "127.0.0.1:${toString termixPort}:8080" ];
        environment = {
          # Termix runs out-of-cluster as `root` inside the container; the
          # `aether` user on the host is the operator identity reflected via
          # the SSH cert, not the container UID.
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

  # OAuth2 proxy — Keycloak OIDC in front of termix.
  # The client secret is provisioned by sops-nix; create the secret in
  # secrets/secrets.yml under `admin_jump.oauth2_proxy_client_secret` and
  # add a matching entry in nix/modules/sops.nix.
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    clientID = "admin-jump";
    clientSecret = null;  # injected from env; see systemd override below
    cookie.secret = null; # likewise
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
      # Require the `admin-jump:user` role minted by the Keycloak client mapper.
      allowed-role = "admin-jump:user";
      pass-access-token = "true";
      pass-authorization-header = "true";
    };
  };

  # sops-nix-managed env file with OAUTH2_PROXY_CLIENT_SECRET and
  # OAUTH2_PROXY_COOKIE_SECRET. The unit's drop-in just sources it.
  systemd.services.oauth2-proxy.serviceConfig.EnvironmentFile =
    config.sops.secrets."admin_jump/oauth2_proxy_env".path;

  sops.secrets."admin_jump/oauth2_proxy_env" = {
    owner = "oauth2-proxy";
    mode  = "0400";
  };

  # Caddy — terminate TLS using step-ca's internal issuance.
  # The step-ca-cert module elsewhere in the lab provisions /etc/ssl/admin
  # via cert-renewer. For first deploy, fall back to Caddy's internal CA so
  # the box is reachable; swap to step-ca once admin.home.shdr.ch is in DNS.
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

  # Firewall: SSH for break-glass, HTTPS for browser path. Nothing else.
  networking.firewall.allowedTCPPorts = [ 22 443 ];

  # OTel scrape for oauth2-proxy + caddy (Prometheus endpoints exposed on
  # localhost; the host's otel-agent ships them upstream).
  aether.otel-agent.prometheusScrapeConfigs = [
    { job_name = "oauth2-proxy"; targets = [ "127.0.0.1:4180" ]; }
    { job_name = "caddy";        targets = [ "127.0.0.1:2019" ]; }
  ];
}
