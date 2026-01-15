# =============================================================================
# Talos Kubernetes Cluster
# =============================================================================
# 3-node cluster with combined control plane + worker roles
# Cilium CNI with L2 announcements for LoadBalancer VIP
#
# Architecture:
#   - talos-trinity (10.0.3.16) - Control plane + Worker
#   - talos-neo     (10.0.3.17) - Control plane + Worker
#   - talos-niobe   (10.0.3.18) - Control plane + Worker
#   - API VIP       (10.0.3.20) - Talos native VIP for kubectl/API server
#   - Workload VIP  (10.0.3.19) - Cilium L2 announced LoadBalancer IP

locals {
  # Filter Talos nodes from VM config
  talos_nodes = { for k, v in local.vm : k => v if startswith(k, "talos_") }

  # Cluster configuration
  talos_cluster_name = "aether-k8s"
  talos_api_vip      = "10.0.3.20" # Talos native VIP for API server (kubectl)
  talos_workload_vip = "10.0.3.19" # Cilium L2 VIP for workload traffic (Gateway)

  # Cluster endpoint uses the API VIP for HA kubectl access
  talos_cluster_endpoint = "https://${local.talos_api_vip}:6443"

  # Keycloak OIDC configuration for kubectl access
  oidc_issuer_url = "https://auth.shdr.ch/realms/aether"
  oidc_client_id  = "kubernetes"

  # Gateway API version
  gateway_api_version = "v1.2.1"
}

# =============================================================================
# Talos Machine Secrets
# =============================================================================
# Generates cluster PKI: CA certs, keys, bootstrap tokens, etc.

resource "talos_machine_secrets" "this" {}

# =============================================================================
# Talos Machine Configuration
# =============================================================================
# Base configuration - patches applied via talos_machine_configuration_apply

data "talos_machine_configuration" "controlplane" {
  for_each = local.talos_nodes

  cluster_name     = local.talos_cluster_name
  cluster_endpoint = local.talos_cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

# Client configuration for talosctl
data "talos_client_configuration" "this" {
  cluster_name         = local.talos_cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for node in local.talos_nodes : node.ip]
  nodes                = [for node in local.talos_nodes : node.ip]
}

# =============================================================================
# Proxmox VM Configuration
# =============================================================================

# Create Talos VMs
resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.talos_nodes

  vm_id       = each.value.id
  name        = each.value.name
  node_name   = each.value.node
  description = "Talos Kubernetes Node - ${local.talos_cluster_name}"
  tags        = ["kubernetes", "talos"]

  # Don't start automatically - wait for config to be ready
  started = true

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # VLAN 3 - Application workloads
  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  # Empty disk for Talos installation
  disk {
    datastore_id = "ceph-vm-disks"
    size         = each.value.disk_gb
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    file_format  = "raw"
  }

  # Talos ISO boot
  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  # Disk first - falls through to ISO when empty, boots from disk after install
  boot_order = ["virtio0", "ide2"]

  # Required for Talos
  bios = "seabios"

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
    timeout = "180s"  # Wait for guest agent - it runs in maintenance mode thanks to extension
  }

  lifecycle {
    ignore_changes = [
      disk[0].file_id,
    ]
  }
}

# =============================================================================
# Cluster Bootstrap
# =============================================================================

# Apply machine configuration to nodes with patches
# Uses DHCP IP discovered from guest agent, config sets static IP for post-install
resource "talos_machine_configuration_apply" "this" {
  for_each = local.talos_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration
  # Use discovered DHCP IP from guest agent (VM is in maintenance mode)
  # Index [7] = eth0 (8th interface in guest agent list)
  endpoint                    = proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses[7][0]
  node                        = proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses[7][0]

  config_patches = [
    # Cluster-wide config
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
        apiServer = {
          extraArgs = {
            "oidc-issuer-url"     = local.oidc_issuer_url
            "oidc-client-id"      = local.oidc_client_id
            "oidc-username-claim" = "preferred_username"
            "oidc-groups-claim"   = "groups"
          }
        }
      }
    }),
    # Per-node machine config
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          # Installer image from Talos Factory (includes qemu-guest-agent extension)
          image = "factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.1"
        }
        network = {
          interfaces = [{
            interface = "ens18"
            addresses = ["${each.value.ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = each.value.gateway
            }]
            vip = {
              ip = local.talos_api_vip
            }
          }]
          nameservers = ["10.0.0.1"]
        }
        time = {
          servers = ["time.cloudflare.com"]
        }
        sysctls = {
          "net.core.bpf_jit_enable"         = "1"
          "net.ipv4.conf.all.forwarding"    = "1"
          "net.ipv6.conf.all.forwarding"    = "1"
          "net.ipv4.conf.all.rp_filter"     = "0"
          "net.ipv4.conf.default.rp_filter" = "0"
        }
      }
    }),
  ]
}

# Bootstrap the cluster (runs on first control plane only)
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.vm.talos_trinity.ip
  node                 = local.vm.talos_trinity.ip
}

# Wait for cluster to be healthy
data "talos_cluster_health" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for node in local.talos_nodes : node.ip]
  control_plane_nodes  = [for node in local.talos_nodes : node.ip]

  timeouts = {
    read = "10m"
  }

  # Skip K8s node ready check - nodes won't be Ready until Cilium CNI is installed
  skip_kubernetes_checks = true
}

# Retrieve kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [data.talos_cluster_health.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.vm.talos_trinity.ip
  node                 = local.vm.talos_trinity.ip
}

# =============================================================================
# Cilium Installation (Helm)
# =============================================================================
# CNI with kube-proxy replacement, L2 announcements, and Gateway API support

resource "helm_release" "cilium" {
  depends_on = [talos_cluster_kubeconfig.this]

  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  namespace        = "kube-system"
  create_namespace = false
  version          = "1.17.0"
  wait             = true
  timeout          = 600

  values = [yamlencode({
    # Talos-specific: kube-proxy replacement
    kubeProxyReplacement = true
    k8sServiceHost       = local.talos_api_vip
    k8sServicePort       = 6443

    # L2 announcements for LoadBalancer services
    l2announcements = { enabled = true }
    externalIPs     = { enabled = true }

    # Hubble observability
    hubble = {
      enabled = true
      relay   = { enabled = true }
      ui      = { enabled = true }
    }

    # Gateway API support
    gatewayAPI = { enabled = true }

    # IPAM mode
    ipam = { mode = "kubernetes" }

    # Operator replicas (single replica for small cluster)
    operator = { replicas = 1 }

    # Talos-specific: cgroup settings
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    # Talos-specific: explicit capabilities
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
  })]
}

# L2 Announcement Policy - enables ARP responses for LoadBalancer IPs
resource "kubernetes_manifest" "cilium_l2_policy" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata = {
      name = "cluster-ingress"
    }
    spec = {
      interfaces      = ["^ens[0-9]+"]
      externalIPs     = true
      loadBalancerIPs = true
    }
  }
}

# LoadBalancer IP Pool - single VIP for all LoadBalancer services
resource "kubernetes_manifest" "cilium_ip_pool" {
  depends_on = [helm_release.cilium]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata = {
      name = "ingress-pool"
    }
    spec = {
      blocks = [{
        start = local.talos_workload_vip
        stop  = local.talos_workload_vip
      }]
    }
  }
}

# RBAC: Map Keycloak 'admin' group to cluster-admin
resource "kubernetes_cluster_role_binding_v1" "oidc_admin" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "oidc-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "Group"
    name      = "admin"
    api_group = "rbac.authorization.k8s.io"
  }
}

# =============================================================================
# Gateway API Installation
# =============================================================================
# CRDs installed via kubectl (one-time bootstrap), resources managed by TF

# Gateway API CRDs - must exist before GatewayClass/Gateway can be created
# This is idempotent (kubectl apply) but won't track CRD state changes
resource "null_resource" "gateway_api_crds" {
  depends_on = [helm_release.cilium]

  triggers = {
    version = local.gateway_api_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo '${talos_cluster_kubeconfig.this.kubeconfig_raw}' > /tmp/talos-kubeconfig
      KUBECONFIG=/tmp/talos-kubeconfig kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${local.gateway_api_version}/experimental-install.yaml
      rm /tmp/talos-kubeconfig
    EOT
  }
}

# GatewayClass - tells Cilium to handle Gateway resources
resource "kubernetes_manifest" "gateway_class" {
  depends_on = [null_resource.gateway_api_crds]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "cilium"
    }
    spec = {
      controllerName = "io.cilium/gateway-controller"
    }
  }
}

# Main Gateway - ingress point for all HTTP traffic
resource "kubernetes_manifest" "main_gateway" {
  depends_on = [kubernetes_manifest.gateway_class]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "main-gateway"
      namespace = "default"
      annotations = {
        "io.cilium/lb-ipam-ips" = local.talos_workload_vip
      }
    }
    spec = {
      gatewayClassName = "cilium"
      listeners = [{
        name     = "http"
        protocol = "HTTP"
        port     = 80
        hostname = "*.apps.home.shdr.ch"
        allowedRoutes = {
          namespaces = {
            from = "All"
          }
        }
      }]
    }
  }
}

# =============================================================================
# Proxmox HA Resources
# =============================================================================
# Enable HA failover for Talos nodes

resource "proxmox_virtual_environment_haresource" "talos" {
  for_each = proxmox_virtual_environment_vm.talos

  resource_id  = "vm:${each.value.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}

# =============================================================================
# Headlamp - Kubernetes Dashboard
# =============================================================================
# Modern Kubernetes UI with OIDC authentication via Keycloak

resource "helm_release" "headlamp" {
  depends_on = [helm_release.cilium]

  name             = "headlamp"
  repository       = "https://kubernetes-sigs.github.io/headlamp/"
  chart            = "headlamp"
  namespace        = "headlamp"
  create_namespace = true
  version          = "0.39.0"
  wait             = true
  timeout          = 300

  values = [yamlencode({
    # OIDC authentication via Keycloak
    config = {
      oidc = {
        clientID  = local.oidc_client_id # "kubernetes" - must match API server
        issuerURL = local.oidc_issuer_url
      }
      # Force HTTPS callback URL (Gateway terminates TLS)
      extraArgs = ["-oidc-callback-url", "https://headlamp.apps.home.shdr.ch/oidc-callback"]
    }

    # Service configuration
    service = {
      type = "ClusterIP"
      port = 80
    }

    # Resource limits for small cluster
    resources = {
      requests = {
        cpu    = "50m"
        memory = "128Mi"
      }
      limits = {
        cpu    = "200m"
        memory = "256Mi"
      }
    }
  })]
}

# HTTPRoute for Headlamp via Gateway API
resource "kubernetes_manifest" "headlamp_route" {
  depends_on = [kubernetes_manifest.main_gateway, helm_release.headlamp]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "headlamp"
      namespace = "headlamp"
    }
    spec = {
      parentRefs = [{
        name      = "main-gateway"
        namespace = "default"
      }]
      hostnames = ["headlamp.apps.home.shdr.ch"]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          kind = "Service"
          name = "headlamp"
          port = 80
        }]
      }]
    }
  }
}

