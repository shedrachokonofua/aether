# AdGuard Home LXC configuration
# DNS server for the home network
{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/lxc-base.nix
  ];

  aether.lxc = {
    hostname = "adguard";
  };

  # AdGuard Home
  services.adguardhome = {
    enable = true;
    mutableSettings = false;  # Declarative config
    openFirewall = true;

    settings = {
      # Web interface
      http = {
        address = "0.0.0.0:3000";
        session_ttl = "720h";
      };

      # DNS settings - matches production config
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        # Upstream DNS servers (parallel mode for speed)
        upstream_dns = [
          "https://dns10.quad9.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
          "https://dns.google/dns-query"
        ];
        upstream_mode = "parallel";
        fastest_timeout = "1s";

        # Bootstrap DNS (for resolving DoH hostnames)
        bootstrap_dns = [
          "9.9.9.10"
          "149.112.112.10"
          "1.1.1.1"
          "8.8.8.8"
        ];

        # Fallback DNS
        fallback_dns = [
          "9.9.9.10"
          "1.1.1.1"
          "8.8.8.8"
        ];

        # DNSSEC disabled (causes issues with some domains)
        enable_dnssec = false;

        # Cache settings
        cache_size = 4194304;  # 4MB

        # Rate limiting disabled
        ratelimit = 0;
        ratelimit_subnet_len_ipv4 = 24;
        ratelimit_subnet_len_ipv6 = 56;

        # Refuse ANY queries (amplification protection)
        refuse_any = true;

        # Blocked hostnames
        blocked_hosts = [
          "version.bind"
          "id.server"
          "hostname.bind"
        ];

        # Performance
        max_goroutines = 300;
        upstream_timeout = "10s";

        # Use private PTR resolvers
        use_private_ptr_resolvers = true;

        # Enable hosts file
        hostsfile_enabled = true;
      };

      # Query log - 90 days retention
      querylog = {
        enabled = true;
        file_enabled = true;
        interval = "2160h";
        size_memory = 1000;
        # Log all queries including answered from cache
        ignored = [];
      };

      # Statistics - 7 days for better trends
      statistics = {
        enabled = true;
        interval = "168h";  # 7 days
        ignored = [];
      };

      # Application logging
      log = {
        enabled = true;
        file = "";  # stdout/journald
        verbose = false;  # Set true for debug
        local_time = true;
        max_size = 100;  # MB
        max_age = 3;     # days
      };

      # Filter lists
      filters = [
        { enabled = true; id = 1; name = "AdGuard DNS filter"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"; }
        { enabled = true; id = 1741404507; name = "HaGeZi's Pro++ Blocklist"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt"; }
        { enabled = true; id = 1741404508; name = "AWAvenue Ads Rule"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_53.txt"; }
        { enabled = true; id = 1741404509; name = "Dandelion Sprout's Anti Push Notifications"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_39.txt"; }
        { enabled = true; id = 1741404510; name = "HaGeZi's Allowlist Referral"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_45.txt"; }
        { enabled = true; id = 1741404511; name = "Perflyst and Dandelion Sprout's Smart-TV Blocklist"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_7.txt"; }
        { enabled = true; id = 1741404512; name = "HaGeZi's Windows/Office Tracker Blocklist"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt"; }
        { enabled = true; id = 1741404513; name = "HaGeZi's Samsung Tracker Blocklist"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_61.txt"; }
        { enabled = true; id = 1741404514; name = "Dandelion Sprout's Game Console Adblock List"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_6.txt"; }
        { enabled = true; id = 1741404515; name = "HaGeZi's Badware Hoster Blocklist"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_55.txt"; }
        { enabled = true; id = 1741404516; name = "HaGeZi's The World's Most Abused TLDs"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_56.txt"; }
        { enabled = true; id = 1741404517; name = "HaGeZi's Threat Intelligence Feeds"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_44.txt"; }
        { enabled = true; id = 1741404518; name = "Dandelion Sprout's Anti-Malware List"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_12.txt"; }
        { enabled = true; id = 1741404519; name = "Phishing URL Blocklist (PhishTank and OpenPhish)"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt"; }
        { enabled = true; id = 1741404520; name = "Malicious URL Blocklist (URLHaus)"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"; }
        { enabled = true; id = 1741404521; name = "uBlock₀ filters – Badware risks"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt"; }
        { enabled = true; id = 1741404522; name = "The Big List of Hacked Malware Web Sites"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt"; }
        { enabled = true; id = 1741404523; name = "Stalkerware Indicators List"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_31.txt"; }
        { enabled = true; id = 1741404524; name = "ShadowWhisperer's Malware List"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_42.txt"; }
        { enabled = true; id = 1741404525; name = "Scam Blocklist by DurableNapkin"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_10.txt"; }
        { enabled = true; id = 1741404526; name = "Phishing Army"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_18.txt"; }
      ];

      # User rules (allowlist overrides)
      user_rules = [
        "www.langflow.store^$important"
        "@@||langflow.store^$important"
        "@@||api.langflow.store^$important"
        "@@||app.lemonade.finance^$important"
        "@@||media.brightdata.com^$important"
        "@@||brightdata.com^$important"
      ];

      # Filtering settings
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        filters_update_interval = 24;
        cache_time = 30;
        safebrowsing_cache_size = 1048576;
        safesearch_cache_size = 1048576;
        parental_cache_size = 1048576;

        # DNS rewrites for internal services
        rewrites = [
          { domain = "*.home.shdr.ch"; answer = "10.0.2.2"; }
          { domain = "home.shdr.ch"; answer = "10.0.2.2"; }
          { domain = "auth.shdr.ch"; answer = "10.0.2.2"; }
          { domain = "ca.shdr.ch"; answer = "192.168.2.235"; }
          { domain = "ssh.gitlab.home.shdr.ch"; answer = "10.0.3.7"; }
          { domain = "smtp.home.shdr.ch"; answer = "10.0.3.4"; }
        ];
      };

      # TLS disabled (handled by reverse proxy)
      tls = {
        enabled = false;
      };

      # DHCP disabled
      dhcp = {
        enabled = false;
      };

      schema_version = 29;
    };
  };

  # Firewall - DNS and admin UI
  networking.firewall.allowedTCPPorts = [
    53    # DNS TCP
    3000  # Admin UI
  ];
  networking.firewall.allowedUDPPorts = [
    53    # DNS UDP
  ];

  # Disable systemd-resolved - AdGuard handles DNS
  services.resolved.enable = false;

  # Fallback nameservers for bootstrap (before AdGuard starts)
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # Route to VyOS networks via VyOS router (for OTEL export)
  # TODO: Add this route on gigahub router instead
  networking.localCommands = ''
    ip route add 10.0.2.0/24 via 192.168.2.231 dev eth0 || true
  '';
}
