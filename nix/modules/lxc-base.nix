# Base configuration for NixOS LXCs
# Provides: SSH CA trust, OTEL monitoring, common packages
{ config, lib, pkgs, modulesPath, ... }:

let
  cfg = config.aether.lxc;
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  options.aether.lxc = {
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Hostname for the LXC";
    };

    otlpEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://10.0.2.3:4318";
      description = "OTLP HTTP endpoint for telemetry";
    };
  };

  config = {
    # Hostname
    networking.hostName = cfg.hostname;

    # SSH with CA trust + authorized_keys fallback
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        StrictModes = false;
        AuthorizedPrincipalsFile = "/etc/ssh/auth_principals/%u";
      };
      extraConfig = ''
        TrustedUserCAKeys /run/ssh-ca/ca_user_key.pub
      '';
    };

    # Principals - allow 'admin' principal to login as root
    environment.etc."ssh/auth_principals/root".text = "admin\n";

    # Load SSH CA public key from cache (seeded by bootstrap_lxc.yml)
    systemd.services.load-ssh-ca-key = {
      description = "Load SSH CA public key from cache";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /run/ssh-ca
        if [ -f /var/lib/ssh-ca/ca_user_key.pub ]; then
          cp /var/lib/ssh-ca/ca_user_key.pub /run/ssh-ca/ca_user_key.pub
          chmod 644 /run/ssh-ca/ca_user_key.pub
        else
          echo "ERROR: SSH CA key not found in /var/lib/ssh-ca/"
          echo "Run bootstrap_lxc.yml to seed the CA key cache"
          exit 1
        fi
      '';
    };

    # Firewall - SSH always allowed
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };

    # Common packages
    environment.systemPackages = with pkgs; [
      curl
      htop
      vim
      jq
    ];

    # OpenTelemetry Collector for monitoring
    # Note: 24.11 has broken 0.112, overlay in flake.nix pulls 0.114
    # See: https://github.com/NixOS/nixpkgs/issues/368321
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      settings = {
        receivers = {
          otlp = {
            protocols = {
              grpc.endpoint = "127.0.0.1:4317";
              http.endpoint = "127.0.0.1:4318";
            };
          };
          journald = {
            directory = "/var/log/journal/";
            storage = "file_storage/journald_cursor_storage";
          };
          hostmetrics = {
            collection_interval = "30s";
            initial_delay = "1s";
            scrapers = {
              cpu = { };
              disk = { };
              filesystem = { };
              load = { };
              memory = { };
              network = { };
              paging = { };
              processes = { };
              process = { };
              system = { };
            };
          };
        };

        processors = {
          batch = {
            send_batch_size = 1000;
            timeout = "10s";
          };
          resource = {
            attributes = [
              { key = "host.name"; value = cfg.hostname; action = "insert"; }
              { key = "service.name"; value = cfg.hostname; action = "insert"; }
              { key = "os.type"; value = "NixOS"; action = "insert"; }
              { key = "os.version"; value = "24.11"; action = "insert"; }
            ];
          };
        };

        extensions = {
          "file_storage/journald_cursor_storage" = {
            directory = "/var/lib/opentelemetry-collector";
          };
        };

        exporters = {
          otlphttp.endpoint = cfg.otlpEndpoint;
        };

        service = {
          telemetry = {
            metrics = {
              readers = [{
                periodic = {
                  exporter = {
                    otlp = {
                      protocol = "http/protobuf";
                      endpoint = cfg.otlpEndpoint;
                    };
                  };
                };
              }];
            };
          };
          extensions = [ "file_storage/journald_cursor_storage" ];
          pipelines = {
            metrics = {
              receivers = [ "otlp" "hostmetrics" ];
              processors = [ "batch" "resource" ];
              exporters = [ "otlphttp" ];
            };
            logs = {
              receivers = [ "otlp" "journald" ];
              processors = [ "batch" "resource" ];
              exporters = [ "otlphttp" ];
            };
            traces = {
              receivers = [ "otlp" ];
              processors = [ "batch" "resource" ];
              exporters = [ "otlphttp" ];
            };
          };
        };
      };
    };

    # Persistent storage directories
    systemd.tmpfiles.rules = [
      "d /var/lib/ssh-ca 0755 root root -"                    # SSH CA key cache
      "d /var/lib/opentelemetry-collector 0755 root root -"   # OTEL cursor storage
    ];

    # NixOS version
    system.stateVersion = "24.11";
  };
}

