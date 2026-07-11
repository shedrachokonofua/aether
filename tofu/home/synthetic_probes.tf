# Explicit HTTP probes for services that are not represented by Kubernetes
# namespace contracts. The blackbox exporter checks the gateway edge, so these
# URLs intentionally use public hostnames rather than VM/LXC addresses.

locals {
  synthetic_probe_off_k8s_specs = {
    "ap.home.shdr.ch" = {
      path        = ""
      namespace   = "home-gateway-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "apprise.home.shdr.ch" = {
      path        = ""
      namespace   = "notifications-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "auth.shdr.ch" = {
      path        = "/realms/aether/.well-known/openid-configuration"
      namespace   = "keycloak"
      exposure    = "public"
      criticality = "high"
    }
    "backrest.home.shdr.ch" = {
      path        = ""
      namespace   = "backup-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "bao.home.shdr.ch" = {
      path        = "/v1/sys/health"
      namespace   = "openbao"
      exposure    = "internal"
      criticality = "high"
    }
    "bastion.home.shdr.ch" = {
      path        = ""
      namespace   = "bastion"
      exposure    = "internal"
      criticality = "normal"
    }
    "caddy.home.shdr.ch" = {
      path        = "/metrics"
      namespace   = "home-gateway-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "clickhouse.home.shdr.ch" = {
      path        = "/ping"
      namespace   = "monitoring-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "cockpit.home.shdr.ch" = {
      path        = ""
      namespace   = "cockpit"
      exposure    = "internal"
      criticality = "normal"
    }
    "dns.home.shdr.ch" = {
      path        = "/control/status"
      namespace   = "adguard"
      exposure    = "internal"
      criticality = "high"
    }
    "fleet.home.shdr.ch" = {
      path        = "/healthz"
      namespace   = "monitoring-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "gitlab.home.shdr.ch" = {
      path        = ""
      namespace   = "gitlab"
      exposure    = "internal"
      criticality = "high"
    }
    "grafana.home.shdr.ch" = {
      path        = "/api/health"
      namespace   = "monitoring-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "ha.home.shdr.ch" = {
      path        = ""
      namespace   = "iot-management-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "hids.home.shdr.ch" = {
      path        = ""
      namespace   = "ids-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "kvm.home.shdr.ch" = {
      path        = ""
      namespace   = "proxmox"
      exposure    = "internal"
      criticality = "normal"
    }
    "loki.home.shdr.ch" = {
      path        = "/ready"
      namespace   = "monitoring-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "m.ha.home.shdr.ch" = {
      path        = ""
      namespace   = "iot-management-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "master.seaweed.home.shdr.ch" = {
      path        = "/cluster/status"
      namespace   = "seaweedfs"
      exposure    = "internal"
      criticality = "high"
    }
    "niobe.home.shdr.ch" = {
      path        = ""
      namespace   = "proxmox"
      exposure    = "internal"
      criticality = "normal"
    }
    "ntfy.home.shdr.ch" = {
      path        = ""
      namespace   = "notifications-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "office-switch.home.shdr.ch" = {
      path        = ""
      namespace   = "network"
      exposure    = "internal"
      criticality = "normal"
    }
    "otel-prometheus.home.shdr.ch" = {
      path        = "/metrics"
      namespace   = "monitoring-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "pi-switch.home.shdr.ch" = {
      path        = ""
      namespace   = "network"
      exposure    = "internal"
      criticality = "normal"
    }
    "prometheus.home.shdr.ch" = {
      path        = "/-/ready"
      namespace   = "monitoring-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "rack-switch.home.shdr.ch" = {
      path        = ""
      namespace   = "network"
      exposure    = "internal"
      criticality = "normal"
    }
    "registry.gitlab.home.shdr.ch" = {
      path        = ""
      namespace   = "gitlab"
      exposure    = "internal"
      criticality = "normal"
    }
    "s3.home.shdr.ch" = {
      path        = ""
      namespace   = "ceph-rgw"
      exposure    = "internal"
      criticality = "high"
    }
    "s3.seaweed.home.shdr.ch" = {
      path        = ""
      namespace   = "seaweedfs"
      exposure    = "internal"
      criticality = "high"
    }
    "seaweed.home.shdr.ch" = {
      path        = ""
      namespace   = "seaweedfs"
      exposure    = "internal"
      criticality = "high"
    }
    "shdr.ch" = {
      path        = ""
      namespace   = "ceph-rgw"
      exposure    = "public"
      criticality = "normal"
    }
    "stats.proxy.home.shdr.ch" = {
      path        = "/metrics"
      namespace   = "home-gateway-stack"
      exposure    = "internal"
      criticality = "normal"
    }
    "sunshine.home.shdr.ch" = {
      path        = ""
      namespace   = "sunshine"
      exposure    = "internal"
      criticality = "normal"
    }
    "ups.home.shdr.ch" = {
      path        = ""
      namespace   = "ups"
      exposure    = "internal"
      criticality = "normal"
    }
    "wazuh.home.shdr.ch" = {
      path        = ""
      namespace   = "ids-stack"
      exposure    = "internal"
      criticality = "high"
    }
    "z.ha.home.shdr.ch" = {
      path        = ""
      namespace   = "iot-management-stack"
      exposure    = "internal"
      criticality = "normal"
    }
  }

  synthetic_probe_off_k8s_targets = [
    for hostname, spec in local.synthetic_probe_off_k8s_specs : {
      url         = "https://${hostname}${spec.path}"
      namespace   = spec.namespace
      hostname    = hostname
      exposure    = spec.exposure
      criticality = spec.criticality
    }
  ]
}
