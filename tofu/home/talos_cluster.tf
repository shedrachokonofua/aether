# =============================================================================
# Talos Kubernetes Cluster
# =============================================================================
# 3-node cluster with combined control plane + worker roles
# Cilium CNI with L2 announcements for LoadBalancer VIP
#
# Architecture:
#   - talos-trinity (10.0.3.16) - Control plane + Worker
#   - talos-neo     (10.0.3.17) - Control plane + Worker + GPU (RTX Pro 6000)
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

  # GPU nodes require q35 + OVMF for PCIe passthrough
  machine = try(each.value.gpu, false) ? "q35" : null
  bios    = try(each.value.gpu, false) ? "ovmf" : "seabios"

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

  # Optional dedicated local-NVMe disk for etcd dataDir (per-node). Pulls etcd
  # off the Ceph-backed root volume to eliminate fsync stalls.
  # Placed at virtio1 (-> /dev/vdb) so the device path is uniform across all
  # nodes regardless of whether they also have a virtio2 (e.g. gpu-storage on
  # neo, which lives at virtio2 -> /dev/vdc).
  dynamic "disk" {
    for_each = try(each.value.etcd_disk_gb, null) != null ? [1] : []
    content {
      datastore_id = try(each.value.etcd_disk_datastore, "local-lvm")
      size         = each.value.etcd_disk_gb
      interface    = "virtio1"
      iothread     = true
      discard      = "on"
      file_format  = "raw"
    }
  }

  # Optional GPU model/state storage disk (neo-only). Mounted on the node at
  # /var/mnt/gpu-storage and exposed to k8s via a static local PV so ComfyUI
  # and llama-swap can co-locate their large weights with the GPU instead of
  # paying Ceph RBD round-trip latency on every model load.
  dynamic "disk" {
    for_each = try(each.value.gpu_storage_disk_gb, null) != null ? [1] : []
    content {
      datastore_id = "local-lvm"
      size         = each.value.gpu_storage_disk_gb
      interface    = "virtio2"
      iothread     = true
      discard      = "on"
      file_format  = "raw"
    }
  }

  dynamic "hostpci" {
    for_each = try(each.value.gpu, false) ? [1] : []
    content {
      device   = "hostpci0"
      id       = "0000:01:00.0"
      xvga     = true
      pcie     = true
      rom_file = "rtx6000.rom"
    }
  }

  dynamic "efi_disk" {
    for_each = try(each.value.gpu, false) ? [1] : []
    content {
      datastore_id      = "local-lvm"
      file_format       = "raw"
      type              = "4m"
      pre_enrolled_keys = false
    }
  }

  cdrom {
    file_id   = try(each.value.gpu, false) ? proxmox_virtual_environment_download_file.talos_nvidia_iso.id : proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  boot_order = ["virtio0", "ide2"]

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

  client_configuration = talos_machine_secrets.this.client_configuration
  # Strip the HostnameConfig sibling doc that the data source emits by
  # default (auto: stable). It conflicts with our static network.hostname
  # below, and the talos provider's strategic merge can't remove fields,
  # only add them. Leaves the rest of the baseline untouched.
  machine_configuration_input = replace(
    data.talos_machine_configuration.controlplane[each.key].machine_configuration,
    "/\n---\napiVersion: v1alpha1\nkind: HostnameConfig\nauto: stable\\s*\n*/",
    "\n"
  )
  endpoint = proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses[7][0]
  node     = proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses[7][0]

  config_patches = concat(
    [
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
            image = try(each.value.gpu, false) ? "factory.talos.dev/installer/${local.talos_nvidia_schematic}:${local.talos_version}" : "factory.talos.dev/installer/${local.talos_schematic}:${local.talos_version}"
          }
          # Pin a stable, human-readable hostname instead of Talos's default
          # machine-id-derived name (talos-4d9-xcj etc.). Required setup:
          #   1) features.stableHostname = false  (don't auto-generate one)
          #   2) Manually strip the existing HostnameConfig sibling doc that
          #      was already materialized at bootstrap (one-time, via
          #      talosctl apply-config — see runbook). Step 1 alone doesn't
          #      remove the persisted sibling doc.
          #   3) Set network.hostname here (the legacy v1alpha1 way).
          features = {
            stableHostname = false
          }
          network = {
            hostname = each.value.name
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
    ],
    # GPU-storage disk: partition /dev/vdc and mount at /var/mnt/gpu-storage,
    # plus recursively bind-mount /var/mnt into kubelet's namespace so the
    # /dev/vdc1 submount is visible to kubelet (and to local-PV-mounted Pods).
    # `rbind` is critical — non-recursive `bind` only captures the top-level
    # /var/mnt and silently misses submounts, so kubelet sees an empty
    # directory on /dev/vda4 instead of the actual GPU storage. `rshared` is
    # for forward propagation of any later mounts under /var/mnt.
    try(each.value.gpu_storage_disk_gb, null) != null ? [yamlencode({
      machine = {
        disks = [{
          device = "/dev/vdc"
          partitions = [{
            mountpoint = "/var/mnt/gpu-storage"
          }]
        }]
        kubelet = {
          extraMounts = [{
            destination = "/var/mnt"
            type        = "bind"
            source      = "/var/mnt"
            options     = ["rbind", "rshared", "rw"]
          }]
        }
      }
    })] : [],

    # Dedicated etcd disk: partition /dev/vdb and mount it at /var/lib/etcd
    # so Talos's etcd service writes there transparently (etcd's data dir is
    # hardcoded to /var/lib/etcd, so we shadow that path with the new disk
    # rather than reconfiguring etcd). Talos formats on first boot; existing
    # /var/lib/etcd contents on EPHEMERAL are shadowed (the member is removed
    # via `talosctl etcd remove-member` before each rolling apply, and the
    # node rejoins as a fresh learner from peers).
    try(each.value.etcd_disk_gb, null) != null ? [yamlencode({
      machine = {
        disks = [{
          device = "/dev/vdb"
          partitions = [{
            mountpoint = "/var/lib/etcd"
          }]
        }]
      }
    })] : [],

    # NVIDIA kernel modules for GPU nodes
    try(each.value.gpu, false) ? [yamlencode({
      machine = {
        kernel = {
          modules = [
            { name = "nvidia" },
            { name = "nvidia_uvm" },
            { name = "nvidia_drm" },
            { name = "nvidia_modeset" },
          ]
        }
      }
    })] : [],
  )
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
  max_relocate = try(local.talos_nodes[each.key].gpu, false) ? 0 : 2
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

  # Media stack migration
  nfs_server_ip       = local.vm.nfs.ip.vyos
  media_stack_ip      = local.vm.media_stack.ip
  rotating_proxy_addr = "${local.vm.home_gateway_stack.ip}:${local.vm.home_gateway_stack.ports.rotating_proxy}"

  depends_on = [talos_cluster_kubeconfig.this]
}
