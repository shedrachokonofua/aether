# Shared Technitium DNS resolver configuration (cluster nodes).
# Replaces adguard-resolver.nix on hosts migrated to Technitium; the service
# is reconciled declaratively by scripts/technitium-apply.sh (oneshot below)
# from config/technitium-settings.json + the per-host overlay built from the
# aether.technitium options each host sets.
{ config, lib, pkgs, modulesPath, ... }:

let
  cfg = config.aether.technitium;
  applyScript = ../../../scripts/technitium-apply.sh;
  baseConfig = ../../../config/technitium-settings.json;
  overlayFile = pkgs.writeText "technitium-overlay.json" (builtins.toJSON {
    settings = {
      dnsServerDomain = cfg.serverDomain;
      # Explicit per-address sockets, NOT wildcard: a 0.0.0.0 UDP socket
      # replies from the interface primary address, so queries to the anycast
      # IP (10.53.0.1, DNAT target with routed failover) would be answered
      # from the node address and discarded by clients as a source mismatch.
      # All three are always-local; the VRRP VIP is deliberately NOT bound -
      # it is a routing next-hop only, health-checked by ARP on the router.
      dnsServerLocalEndPoints = [
        "${cfg.cluster.nodeIp}:53"
        "10.53.0.1:53"
        "127.0.0.1:53"
      ];
    };
    cluster = cfg.cluster;
  });
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../../modules/base.nix
  ];

  options.aether.technitium = {
    serverDomain = lib.mkOption {
      type = lib.types.str;
      description = "This node's cluster identity FQDN (resolvable via networking.hosts pins).";
    };
    cluster = lib.mkOption {
      type = lib.types.attrs;
      description = "Cluster block for the apply overlay: {mode=primary, domain, nodeIp} or {mode=secondary, nodeIp, primaryUrl, primaryIp}.";
    };
    vrrpPriority = lib.mkOption {
      type = lib.types.int;
      description = "VRRP priority for the DNS VIP election.";
    };
    vrrpPeerAddress = lib.mkOption {
      type = lib.types.str;
      description = "The other home node's address for unicast VRRP peering.";
    };
  };

  config = {

  services.technitium-dns-server = {
    enable = true;
    openFirewall = false;
    # 15.4.0 cluster-wide (matches rama's container tag; primary ns2 must not
    # trail its secondaries). Vendored under nix/packages because nixos-25.11
    # carries 15.2 (SDK 9) and 15.4 targets .NET 10; drop the vendor once
    # nixpkgs ships >= 15.4.
    package = pkgs.callPackage ../../packages/technitium-dns-server/package.nix {
      technitium-dns-server-library =
        pkgs.callPackage ../../packages/technitium-dns-server-library/package.nix { };
    };
  };

  # 2026-07-16 incident rule: services on a resolver box get hard resource
  # caps so nothing can thrash the host into DNS starvation. .NET does not
  # honor cgroup limits for its GC heap by default - cap both.
  systemd.services.technitium-dns-server = {
    environment.DOTNET_GCHeapHardLimitPercent = "60";
    serviceConfig = {
      MemoryHigh = "1G";
      MemoryMax = "1536M";
      # Static identity instead of DynamicUser: with DynamicUser, LogsDirectory
      # becomes a /var/log/private (0700) symlink the OTel collector cannot
      # traverse. Log Exporter writes /var/log/technitium/query.ndjson; the
      # collector (User=adguardhome) tails it, so dir and files must be
      # world-readable.
      DynamicUser = lib.mkForce false;
      User = "technitium";
      Group = "technitium";
      LogsDirectory = "technitium";
      LogsDirectoryMode = "0755";
      UMask = lib.mkForce "0022";
    };
  };

  users.groups.technitium = {};
  users.users.technitium = {
    isSystemUser = true;
    group = "technitium";
  };

  # Reconcile Technitium state from the shared declarative config. Re-runs on
  # every switch-to-configuration whenever config/script content changes (the
  # unit's store path changes), and is idempotent.
  systemd.services.technitium-apply = {
    description = "Apply declarative Technitium DNS configuration";
    after = [ "technitium-dns-server.service" "network-online.target" ];
    requires = [ "technitium-dns-server.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.bash pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep ];
    environment.SECRETS_DIR = "/var/lib/technitium-apply";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "technitium-apply";
      StateDirectoryMode = "0700";
    };
    script = "bash ${applyScript} ${baseConfig} ${overlayFile}";
  };

  # Fixed collector identity + hard caps, carried over from the AdGuard era
  # (2026-07-16 incident); the group also grants query-log read access.
  users.groups.adguardhome = {};
  users.users.adguardhome = {
    isSystemUser = true;
    group = "adguardhome";
  };

  systemd.services.opentelemetry-collector.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "adguardhome";
    Group = "adguardhome";
    # Historical replay must never starve DNS: hard-cap the collector so
    # catchup is slow instead of the resolver being unresponsive.
    CPUQuota = "25%";
    MemoryHigh = "256M";
    MemoryMax = "512M";
    IOWeight = 10;
    Nice = 10;
  };

  # Per-query NDJSON stream from the Technitium Log Exporter app -> Loki.
  # Fields: timestamp, clientIp, protocol, responseType (verdict incl.
  # Blocked), responseCode, question{questionName,questionType}, answers[].
  aether.otel-agent.jsonFilelogs.technitium_querylog = {
    include = [ "/var/log/technitium/query.ndjson*" ];
    timestampField = "timestamp";
    timestampLayoutType = "gotime";
    timestampLayout = "2006-01-02T15:04:05.000Z";
    startAt = "beginning";
    resourceAttributes = {
      "log.source" = "technitium_querylog";
      "dns.log.type" = "query";
    };
  };

  # The exporter app keeps its file handle open; copytruncate is required so
  # rotation does not orphan the live fd.
  services.logrotate.settings."technitium-query" = {
    files = "/var/log/technitium/query.ndjson";
    frequency = "daily";
    rotate = 3;
    size = "256M";
    copytruncate = true;
    missingok = true;
    notifempty = true;
  };

  networking.firewall.allowedTCPPorts = [
    53
    5380 # web service / API (admin via Caddy, apply oneshot)
    53443 # cluster HTTPS web service (ns3 sync)
  ];
  networking.firewall.allowedUDPPorts = [
    53
  ];

  # 2026-07-18 DNS HA: the VIP is the DNAT target's next-hop on the router.
  # The dig check catches the 2026-07-16 "accepting but stalling" failure mode.
  # If both nodes fail checks nobody holds the VIP intentionally; the router
  # failover route then flips to rama.
  services.keepalived = {
    enable = true;
    vrrpInstances.DNS53 = {
      interface = "eth0";
      virtualRouterId = 53;
      priority = cfg.vrrpPriority;
      noPreempt = false;
      virtualIps = [
        { addr = "192.168.2.238/24"; }
      ];
      trackScripts = [ "DNS53_CHECK" ];
      # Unicast VRRP: multicast 224.0.0.18 does not survive the oracle<->
      # trinity L2 path (IGMP snooping) - 2026-07-18 drill found both nodes
      # MASTER (split-brain), VIP held twice, ARP roulette deciding service.
      unicastSrcIp = cfg.cluster.nodeIp;
      unicastPeers = [ cfg.vrrpPeerAddress ];
    };
    vrrpScripts.DNS53_CHECK = {
      # dig prints ";; communications error" diagnostics to STDOUT even with
      # +short (2026-07-18 drill: a dead resolver PASSED `grep -q .`), so
      # strip ";"-prefixed diagnostic lines first. SERVFAIL yields no answer
      # rows either way - only a real SOA answer produces a non-";" line.
      script = toString (pkgs.writeShellScript "dns53-check" ''
        ${pkgs.dnsutils}/bin/dig @127.0.0.1 dns.home.shdr.ch SOA +short +time=1 +tries=1 2>/dev/null | ${pkgs.gnugrep}/bin/grep -v '^;' | ${pkgs.gnugrep}/bin/grep -q .
      '');
      interval = 2;
      fall = 3;
      rise = 2;
    };
  };

  # keepalived references script user keepalived_script but the NixOS module
  # does not create it; without it keepalived DISABLES the track script at
  # startup ("Script user 'keepalived_script' does not exist") and VRRP runs
  # blind - found in the 2026-07-18 failover drill: a dead resolver kept the
  # VIP because no health check ever executed.
  users.groups.keepalived_script = { };
  users.users.keepalived_script = {
    isSystemUser = true;
    group = "keepalived_script";
  };

  networking.interfaces.lo.ipv4.addresses = [
    {
      address = "10.53.0.1";
      prefixLength = 32;
    }
  ];

  networking.firewall.extraInputRules = "ip protocol vrrp accept";

  services.resolved.enable = false;

  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # Cluster node names must resolve without depending on DNS being up.
  networking.hosts = {
    "192.168.2.236" = [ "ns1.dns.home.shdr.ch" ];
    "192.168.2.237" = [ "ns2.dns.home.shdr.ch" ];
    "10.3.0.10" = [ "ns3.dns.home.shdr.ch" ];
  };

  # Static routes to the internal VLANs and the WireGuard fabric (OCI cluster
  # peer) via the VyOS mgmt leg.
  systemd.services.add-internal-route = {
    description = "Add routes to internal networks";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.iproute2}/bin/ip route replace 10.0.0.0/8 via 192.168.2.231 dev eth0
      ${pkgs.iproute2}/bin/ip route replace 10.3.0.0/16 via 192.168.2.231 dev eth0
    '';
  };

  };
}
