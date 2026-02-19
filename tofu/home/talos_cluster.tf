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
  talos_vcluster_vip = "10.0.3.21" # Cilium L2 VIP for Seven30 vcluster API

  # Cluster endpoint uses the API VIP for HA kubectl access
  talos_cluster_endpoint = "https://${local.talos_api_vip}:6443"

  # Keycloak OIDC configuration for kubectl access
  oidc_issuer_url = "https://auth.shdr.ch/realms/aether"
  oidc_client_id  = "kubernetes"

  # Kubernetes service account issuer (for workload identity / IRSA-style STS)
  k8s_serviceaccount_issuer = "https://oidc.k8s.home.shdr.ch"

  # Gateway API version
  gateway_api_version = "v1.2.1"
}

# =============================================================================
# Talos Machine Secrets
# =============================================================================

resource "talos_machine_secrets" "this" {}

# =============================================================================
# Talos Machine Configuration
# =============================================================================

data "talos_machine_configuration" "controlplane" {
  for_each = local.talos_nodes

  cluster_name     = local.talos_cluster_name
  cluster_endpoint = local.talos_cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

data "talos_client_configuration" "this" {
  cluster_name         = local.talos_cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for node in local.talos_nodes : node.ip]
  nodes                = [for node in local.talos_nodes : node.ip]
}

# =============================================================================
# Proxmox VM Configuration
# =============================================================================

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.talos_nodes

  vm_id       = each.value.id
  name        = each.value.name
  node_name   = each.value.node
  description = "Talos Kubernetes Node - ${local.talos_cluster_name}"
  tags        = ["kubernetes", "talos"]
  started     = true

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    size         = each.value.disk_gb
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    file_format  = "raw"
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  boot_order = ["virtio0", "ide2"]
  bios       = "seabios"

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
    timeout = "180s"
  }

  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}

# =============================================================================
# Cluster Bootstrap
# =============================================================================

resource "talos_machine_configuration_apply" "this" {
  for_each = local.talos_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration
  endpoint                    = proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses[7][0]
  node                        = proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses[7][0]

  config_patches = [
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
        network                        = { cni = { name = "none" } }
        proxy                          = { disabled = true }
        apiServer = {
          extraArgs = {
            "oidc-issuer-url"        = local.oidc_issuer_url
            "oidc-client-id"         = local.oidc_client_id
            "oidc-username-claim"    = "preferred_username"
            "oidc-groups-claim"      = "groups"
            "service-account-issuer" = local.k8s_serviceaccount_issuer
          }
        }
      }
    }),
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          image = "factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.1"
        }
        network = {
          interfaces = [{
            interface = "ens18"
            addresses = ["${each.value.ip}/24"]
            routes    = [{ network = "0.0.0.0/0", gateway = each.value.gateway }]
            vip       = { ip = local.talos_api_vip }
          }]
          nameservers = ["10.0.0.1"]
        }
        time = { servers = ["time.cloudflare.com"] }
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

resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.vm.talos_trinity.ip
  node                 = local.vm.talos_trinity.ip
}

data "talos_cluster_health" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration   = talos_machine_secrets.this.client_configuration
  endpoints              = [for node in local.talos_nodes : node.ip]
  control_plane_nodes    = [for node in local.talos_nodes : node.ip]
  skip_kubernetes_checks = true

  timeouts = { read = "10m" }
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [data.talos_cluster_health.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.vm.talos_trinity.ip
  node                 = local.vm.talos_trinity.ip
}

# =============================================================================
# Proxmox HA Resources
# =============================================================================

resource "proxmox_virtual_environment_haresource" "talos" {
  for_each = proxmox_virtual_environment_vm.talos

  resource_id  = "vm:${each.value.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}

# =============================================================================
# Kubernetes Workloads Module
# =============================================================================

module "kubernetes" {
  source = "./kubernetes"

  cluster_name        = local.talos_cluster_name
  api_vip             = local.talos_api_vip
  workload_vip        = local.talos_workload_vip
  vcluster_vip        = local.talos_vcluster_vip
  oidc_issuer_url     = local.oidc_issuer_url
  oidc_client_id      = local.oidc_client_id
  gateway_api_version = local.gateway_api_version
  kubeconfig_raw      = talos_cluster_kubeconfig.this.kubeconfig_raw
  secrets             = var.secrets

  # Crossplane Keycloak provider credentials
  keycloak_url                  = "https://auth.shdr.ch"
  keycloak_client_id            = keycloak_openid_client.crossplane.client_id
  keycloak_client_secret        = keycloak_openid_client.crossplane.client_secret
  openwebui_oauth_client_secret = keycloak_openid_client.openwebui.client_secret
  litellm_mcp_url               = "http://${local.vm.ai_tool_stack.ip}:${local.vm.ai_tool_stack.ports.litellm}/mcp"

  depends_on = [talos_cluster_kubeconfig.this]
}
