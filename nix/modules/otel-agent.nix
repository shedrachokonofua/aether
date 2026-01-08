# OpenTelemetry Collector Agent Module
# Reusable module for VM/LXC monitoring - mirrors ansible/roles/vm_monitoring_agent
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.aether.otel-agent;
in
{
  options.aether.otel-agent = {
    enable = mkEnableOption "Aether OTEL monitoring agent";

    otlpEndpoint = mkOption {
      type = types.str;
      default = "https://otel.home.shdr.ch";
      description = "OTLP HTTP endpoint to export telemetry to";
    };

    # Parameterized scrape configs - like prometheus_scrape_configs in Ansible
    prometheusScrapeConfigs = mkOption {
      type = types.listOf (types.submodule {
        options = {
          job_name = mkOption { type = types.str; };
          scrape_interval = mkOption { type = types.str; default = "15s"; };
          targets = mkOption { type = types.listOf types.str; };
        };
      });
      default = [];
      example = [
        { job_name = "caddy"; scrape_interval = "15s"; targets = [ "localhost:2019" ]; }
        { job_name = "adguard"; scrape_interval = "15s"; targets = [ "localhost:9618" ]; }
      ];
      description = "Prometheus scrape configurations for local services";
    };

    hostMetrics = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable host metrics collection (CPU, memory, disk, etc.)";
      };
      collectionInterval = mkOption {
        type = types.str;
        default = "15s";
        description = "Collection interval for host metrics";
      };
      initialDelay = mkOption {
        type = types.str;
        default = "1s";
        description = "Initial delay before collecting host metrics";
      };
    };

    journald = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable journald log collection";
      };
      units = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "sshd" "nginx" ];
        description = "Specific systemd units to monitor (empty = all)";
      };
    };

    filelog = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable file log collection";
      };
      patterns = mkOption {
        type = types.listOf types.str;
        default = [
          "/var/log/*.log"
        ];
        example = [
          "/var/log/*.log"
          "/var/lib/docker/containers/*/*-json.log"
        ];
        description = "File patterns to collect logs from";
      };
    };

    jsonFilelogs = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          include = mkOption {
            type = types.listOf types.str;
            description = "File patterns to include";
          };
          exclude = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "File patterns to exclude";
          };
          timestampField = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "ts";
            description = "JSON field containing epoch timestamp (null = use log time)";
          };
          resourceAttributes = mkOption {
            type = types.attrsOf types.str;
            default = {};
            example = { "log.source" = "zeek"; };
            description = "Resource attributes to add (useful for routing)";
          };
        };
      });
      default = {};
      example = {
        zeek = {
          include = [ "/var/lib/zeek/logs/*.log" "/var/lib/zeek/logs/**/*.log" ];
          exclude = [ "/var/lib/zeek/logs/stats.log" ];
          timestampField = "ts";
          resourceAttributes = { "log.source" = "zeek"; };
        };
      };
      description = "Named JSON filelog receivers with automatic parsing";
    };

    otlpReceiver = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable OTLP receiver for receiving telemetry from apps";
      };
    };

    storagePath = mkOption {
      type = types.str;
      default = "/var/lib/opentelemetry-collector";
      description = "Path for OTEL collector persistent storage (cursor positions, etc.)";
    };
  };

  config = mkIf cfg.enable {
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      settings = {
        receivers = mkMerge [
          # OTLP receiver for apps to send telemetry
          (mkIf cfg.otlpReceiver.enable {
            otlp = {
              protocols = {
                grpc = { endpoint = "127.0.0.1:4317"; };
                http = { endpoint = "127.0.0.1:4318"; };
              };
            };
          })

          # Prometheus receiver (if scrape configs provided)
          (mkIf (cfg.prometheusScrapeConfigs != []) {
            prometheus = {
              config = {
                scrape_configs = map (sc: {
                  job_name = sc.job_name;
                  scrape_interval = sc.scrape_interval;
                  static_configs = [{ targets = sc.targets; }];
                }) cfg.prometheusScrapeConfigs;
              };
            };
          })

          # Host metrics receiver
          (mkIf cfg.hostMetrics.enable {
            hostmetrics = {
              collection_interval = cfg.hostMetrics.collectionInterval;
              initial_delay = cfg.hostMetrics.initialDelay;
              scrapers = {
                cpu = {};
                disk = {};
                filesystem = {};
                load = {};
                memory = {};
                network = {};
                paging = {};
                processes = {};
                process = {};
                system = {};
              };
            };
          })

          # Journald receiver
          (mkIf cfg.journald.enable {
            journald = {
              directory = "/var/log/journal";
              storage = "file_storage/journald_checkpoint";
            } // (optionalAttrs (cfg.journald.units != []) {
              matches = map (unit: { _SYSTEMD_UNIT = unit; }) cfg.journald.units;
            });
          })

          # Filelog receiver
          (mkIf cfg.filelog.enable {
            filelog = {
              storage = "file_storage/filelog_checkpoint";
              include = cfg.filelog.patterns;
            };
          })

          # JSON filelog receivers (generic, configurable per-VM)
          (mapAttrs' (name: jfCfg: nameValuePair "filelog/${name}" ({
            storage = "file_storage/${name}_checkpoint";
            include = jfCfg.include;
            exclude = jfCfg.exclude;
            start_at = "end";
            include_file_name = true;
            operators = [
              ({
                type = "json_parser";
              } // optionalAttrs (jfCfg.timestampField != null) {
                timestamp = {
                  parse_from = "attributes.${jfCfg.timestampField}";
                  layout_type = "epoch";
                  layout = "s";
                };
              })
            ];
          } // optionalAttrs (jfCfg.resourceAttributes != {}) {
            resource = jfCfg.resourceAttributes;
          })) cfg.jsonFilelogs)
        ];

        # Extensions for persistent storage (cursor positions)
        extensions = mkMerge [
          (mkIf cfg.journald.enable {
            "file_storage/journald_checkpoint" = {
              directory = cfg.storagePath;
              create_directory = true;
            };
          })
          (mkIf cfg.filelog.enable {
            "file_storage/filelog_checkpoint" = {
              directory = cfg.storagePath;
              create_directory = true;
            };
          })
          # JSON filelog checkpoints
          (mapAttrs' (name: _: nameValuePair "file_storage/${name}_checkpoint" {
            directory = cfg.storagePath;
            create_directory = true;
          }) cfg.jsonFilelogs)
        ];

        processors = {
          batch = {
            send_batch_size = 1000;
            timeout = "10s";
          };
          # Drop otelcol-contrib file discovery spam from journald before export
          "filter/drop_otel_noise" = {
            error_mode = "ignore";  # Skip logs where condition can't be evaluated (e.g., no SYSLOG_IDENTIFIER)
            logs = {
              log_record = [
                ''body["SYSLOG_IDENTIFIER"] == "otelcol-contrib"''
              ];
            };
          };
          # Use resourcedetection to auto-detect hostname from OS
          resourcedetection = {
            detectors = [ "system" ];
            system = {
              hostname_sources = [ "os" ];
              resource_attributes = {
                "host.name".enabled = true;
                "os.type".enabled = true;
              };
            };
          };
          # Set service.name from detected host.name
          transform = {
            log_statements = [{
              context = "resource";
              statements = [
                ''set(attributes["service.name"], attributes["host.name"]) where attributes["service.name"] == nil''
              ];
            }];
            metric_statements = [{
              context = "resource";
              statements = [
                ''set(attributes["service.name"], attributes["host.name"]) where attributes["service.name"] == nil''
              ];
            }];
          };
          # Add static attributes
          resource = {
            attributes = [
              { key = "os.type"; value = "NixOS"; action = "insert"; }
            ];
          };
        };

        exporters = {
          otlphttp = {
            endpoint = cfg.otlpEndpoint;
          };
        };

        service = {
          # Only log warnings/errors - info level logs file discovery spam
          telemetry.logs = {
            level = "WARN";
            encoding = "json";
          };

          extensions =
            (optional cfg.journald.enable "file_storage/journald_checkpoint") ++
            (optional cfg.filelog.enable "file_storage/filelog_checkpoint") ++
            (map (name: "file_storage/${name}_checkpoint") (attrNames cfg.jsonFilelogs));
          pipelines = {
            metrics = {
              receivers =
                (optional cfg.otlpReceiver.enable "otlp") ++
                (optional (cfg.prometheusScrapeConfigs != []) "prometheus") ++
                (optional cfg.hostMetrics.enable "hostmetrics");
              processors = [ "batch" "resourcedetection" "transform" "resource" ];
              exporters = [ "otlphttp" ];
            };
            logs = {
              receivers =
                (optional cfg.otlpReceiver.enable "otlp") ++
                (optional cfg.journald.enable "journald") ++
                (optional cfg.filelog.enable "filelog") ++
                (map (name: "filelog/${name}") (attrNames cfg.jsonFilelogs));
              processors = [ "filter/drop_otel_noise" "batch" "resourcedetection" "transform" "resource" ];
              exporters = [ "otlphttp" ];
            };
            traces = mkIf cfg.otlpReceiver.enable {
              receivers = [ "otlp" ];
              processors = [ "batch" "resourcedetection" "transform" "resource" ];
              exporters = [ "otlphttp" ];
            };
          };
        };
      };
    };

    # Wait for cloud-init-hostname to complete so hostname is set correctly (VMs only)
    systemd.services.opentelemetry-collector.after =
      optional config.services.cloud-init.enable "cloud-init-hostname.service";
  };
}
