# =============================================================================
# Talos Kubernetes Cluster
# =============================================================================
# 3-node control plane with additional worker-only nodes
# Cilium CNI with L2 announcements for LoadBalancer VIP
#
# Architecture:
#   - talos-trinity (10.0.3.16) - Control plane + Worker
#   - talos-neo     (10.0.3.17) - Control plane + Worker + GPU (RTX Pro 6000)
#   - talos-niobe   (10.0.3.18) - Control plane + Worker
#   - talos-smith   (10.0.3.22) - Worker + GPU (GTX 1660 Super)
#   - talos-mouse   (10.0.3.25) - ARM Worker (Raspberry Pi 4)
#   - API VIP       (10.0.3.20) - Talos native VIP for kubectl/API server
#   - Workload VIP  (10.0.3.19) - Cilium L2 announced LoadBalancer IP

locals {
  # Talos roles are explicit so worker-only nodes do not accidentally join etcd.
  talos_nodes = { for k, v in local.vm : k => v if startswith(k, "talos_") }
  talos_vm_nodes = {
    for k, v in local.talos_nodes : k => v
    if try(v.platform, "proxmox") == "proxmox"
  }
  talos_baremetal_nodes = {
    for k, v in local.talos_nodes : k => v
    if try(v.platform, "proxmox") == "baremetal"
  }
  talos_controlplane_nodes = {
    for k, v in local.talos_nodes : k => v
    if try(v.role, "controlplane") == "controlplane"
  }
  talos_worker_nodes = {
    for k, v in local.talos_nodes : k => v
    if try(v.role, "controlplane") == "worker"
  }

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
  for_each = local.talos_controlplane_nodes

  cluster_name     = local.talos_cluster_name
  cluster_endpoint = local.talos_cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

data "talos_machine_configuration" "worker" {
  for_each = local.talos_worker_nodes

  cluster_name     = local.talos_cluster_name
  cluster_endpoint = local.talos_cluster_endpoint
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

data "talos_client_configuration" "this" {
  cluster_name         = local.talos_cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for node in local.talos_controlplane_nodes : node.ip]
  nodes                = [for node in local.talos_nodes : node.ip]
}

# =============================================================================
# Proxmox VM Configuration
# =============================================================================

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.talos_vm_nodes

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
    datastore_id = try(each.value.disk_datastore, "ceph-vm-disks")
    size         = each.value.disk_gb
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    file_format  = "raw"
  }

  # Optional dedicated local-NVMe disk for etcd dataDir (per-node).
  # New CI nodes should keep etcd on the local Talos root disk instead; this
  # remains only for existing/manual rollback compatibility.
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

  # Legacy etcd disk kept attached during migration back to root-disk etcd.
  # Talos does not mount this disk; it remains only to avoid mutating/deleting
  # the previous virtio1 etcd volume in the same operation that changes root.
  dynamic "disk" {
    for_each = try(each.value.legacy_etcd_disk_gb, null) != null ? [1] : []
    content {
      datastore_id = try(each.value.legacy_etcd_disk_datastore, try(each.value.etcd_disk_datastore, "local-lvm"))
      size         = each.value.legacy_etcd_disk_gb
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

  # Optional CI disk. Mounted on the node at /var/mnt/ci and consumed by GitLab
  # Runner hostPath mounts for build/cache/container scratch. Uses virtio3
  # deliberately so it cannot collide with legacy virtio1 etcd disks or neo's
  # virtio2 GPU storage during rolling migration. Talos device names are
  # compacted by the guest, so a virtio3 disk appears after the attached lower
  # numbered virtio disks: /dev/vdb with root+CI only, /dev/vdc with a legacy
  # etcd disk or GPU storage disk, and /dev/vdd when both are present.
  dynamic "disk" {
    for_each = try(each.value.ci_disk_gb, null) != null ? [1] : []
    content {
      datastore_id = try(each.value.ci_disk_datastore, try(each.value.disk_datastore, "local-lvm"))
      size         = each.value.ci_disk_gb
      interface    = "virtio3"
      iothread     = true
      discard      = "on"
      file_format  = "raw"
    }
  }

  dynamic "hostpci" {
    for_each = try(each.value.gpu, false) ? [1] : []
    content {
      device   = "hostpci0"
      id       = each.value.gpu_hostpci_id
      xvga     = try(each.value.gpu_xvga, true)
      pcie     = try(each.value.gpu_pcie, true)
      rom_file = try(each.value.gpu_rom_file, null)
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

  depends_on = [proxmox_virtual_environment_vm.talos]

  client_configuration = talos_machine_secrets.this.client_configuration
  # Strip the HostnameConfig sibling doc that the data source emits by
  # default (auto: stable). It conflicts with our static network.hostname
  # below, and the talos provider's strategic merge can't remove fields,
  # only add them. Leaves the rest of the baseline untouched.
  machine_configuration_input = replace(
    try(
      data.talos_machine_configuration.controlplane[each.key].machine_configuration,
      data.talos_machine_configuration.worker[each.key].machine_configuration,
    ),
    "/\n---\napiVersion: v1alpha1\nkind: HostnameConfig\nauto: stable\\s*\n*/",
    "\n"
  )
  endpoint = try(each.value.bootstrap_ip, each.value.ip)
  node     = try(each.value.bootstrap_ip, each.value.ip)

  config_patches = concat(
    [
      contains(keys(local.talos_controlplane_nodes), each.key) ? yamlencode({
        cluster = {
          allowSchedulingOnControlPlanes = true
          network                        = { cni = { name = "none" } }
          proxy                          = { disabled = true }
          apiServer = {
            extraArgs = {
              "oidc-issuer-url"          = local.oidc_issuer_url
              "oidc-client-id"           = local.oidc_client_id
              "oidc-username-claim"      = "preferred_username"
              "oidc-groups-claim"        = "groups"
              "service-account-issuer"   = local.k8s_serviceaccount_issuer
              "service-account-jwks-uri" = "${local.k8s_serviceaccount_issuer}/openid/v1/jwks"
              # Enables IRSA-style flows: lets external verifiers (RGW STS)
              # fetch /.well-known/openid-configuration + /openid/v1/jwks
              # without an Authorization header. RBAC still gates everything
              # else; the `oidc-discovery-public` ClusterRoleBinding scopes
              # what unauthenticated callers can actually read.
              "anonymous-auth" = "true"
            }
          }
        }
        }) : yamlencode({
        cluster = {
          network = { cni = { name = "none" } }
          proxy   = { disabled = true }
        }
      }),
      yamlencode({
        machine = merge(
          {
            install = {
              disk = try(each.value.install_disk, "/dev/vda")
              image = try(
                each.value.install_image,
                try(each.value.hardware, "") == "rpi" ? "factory.talos.dev/installer/${try(each.value.model, "") == "raspberry-pi-5" ? local.talos_rpi5_schematic : local.talos_rpi_schematic}:v1.12.7" : try(each.value.gpu, false) ? "factory.talos.dev/installer/${local.talos_nvidia_schematic}:${local.talos_version}" : "factory.talos.dev/installer/${local.talos_schematic}:${local.talos_version}"
              )
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
              interfaces = [
                merge(
                  {
                    interface = try(each.value.network_interface, "ens18")
                    addresses = ["${each.value.ip}/24"]
                    routes    = [{ network = "0.0.0.0/0", gateway = each.value.gateway }]
                  },
                  contains(keys(local.talos_controlplane_nodes), each.key) ? {
                    vip = { ip = local.talos_api_vip }
                  } : {}
                )
              ]
              nameservers = try(each.value.nameservers, ["10.0.0.1"])
            }
            time = { servers = ["time.cloudflare.com"] }
            sysctls = {
              "net.core.bpf_jit_enable"         = "1"
              "net.ipv4.conf.all.forwarding"    = "1"
              "net.ipv6.conf.all.forwarding"    = "1"
              "net.ipv4.conf.all.rp_filter"     = "0"
              "net.ipv4.conf.default.rp_filter" = "0"
            }
          },
          try(each.value.pool, null) != null || try(each.value.hardware, null) != null ? {
            kubelet = {
              extraArgs = {
                "node-labels" = join(",", compact([
                  try(each.value.pool, null) != null ? "aether.sh/node-pool=${each.value.pool}" : "",
                  try(each.value.hardware, null) != null ? "aether.sh/hardware=${each.value.hardware}" : "",
                ]))
              }
            }
          } : {}
        )
      }),
    ],
    # CI disk: partition and mount at /var/mnt/ci. Linux compacts virtio names
    # by enumeration order, so virtio3's guest device depends on the lower
    # numbered disks attached to the VM.
    try(each.value.ci_disk_gb, null) != null ? [yamlencode({
      machine = {
        disks = [{
          device = (
            try(each.value.gpu_storage_disk_gb, null) != null && try(each.value.legacy_etcd_disk_gb, null) != null ? "/dev/vdd" :
            try(each.value.gpu_storage_disk_gb, null) != null || try(each.value.legacy_etcd_disk_gb, null) != null ? "/dev/vdc" :
            "/dev/vdb"
          )
          partitions = [{
            mountpoint = "/var/mnt/ci"
          }]
        }]
      }
    })] : [],

    # GPU-storage disk: partition and mount at /var/mnt/gpu-storage. virtio2 is
    # /dev/vdc while the legacy virtio1 etcd disk exists, otherwise /dev/vdb.
    try(each.value.gpu_storage_disk_gb, null) != null ? [yamlencode({
      machine = {
        disks = [{
          device = try(each.value.legacy_etcd_disk_gb, null) != null ? "/dev/vdc" : "/dev/vdb"
          partitions = [{
            mountpoint = "/var/mnt/gpu-storage"
          }]
        }]
      }
    })] : [],

    # Recursively bind-mount /var/mnt into kubelet's namespace so submounts
    # like /var/mnt/ci and /var/mnt/gpu-storage are visible to hostPath
    # and static local-PV mounted Pods. `rbind` is critical; a non-recursive bind
    # only captures the top-level /var/mnt and misses submounts.
    try(each.value.ci_disk_gb, null) != null || try(each.value.gpu_storage_disk_gb, null) != null ? [yamlencode({
      machine = {
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
    # Pi 5 silent ethernet wedge workaround. macb/RP1 driver in kernel 6.18.x
    # locks up under TSO/SG load — link stays "up" but no packets flow, only
    # power-cycle recovers. Ubuntu LP #2133877 + Cilium #43198. Disabling
    # tx-tcp-segmentation + tx-scatter-gather is the most-cited mitigation
    # until the netdev patch series lands in a released kernel.
    try(each.value.model, "") == "raspberry-pi-5" ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "EthernetConfig"
      name       = "end0"
      features = {
        "tx-tcp-segmentation" = false
        "tx-scatter-gather"   = false
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
  endpoints              = [for node in local.talos_controlplane_nodes : node.ip]
  control_plane_nodes    = [for node in local.talos_controlplane_nodes : node.ip]
  worker_nodes           = [for node in local.talos_worker_nodes : node.ip]
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
  immich_oauth_client_secret    = keycloak_openid_client.immich.client_secret
  nextcloud_oauth_client_secret = keycloak_openid_client.nextcloud.client_secret
  coder_oauth_client_secret     = keycloak_openid_client.coder.client_secret
  affine_oauth_client_secret    = keycloak_openid_client.affine.client_secret
  karakeep_oauth_client_secret  = keycloak_openid_client.karakeep.client_secret
  memos_oauth_client_secret        = keycloak_openid_client.memos.client_secret
  nextexplorer_oauth_client_secret = keycloak_openid_client.nextexplorer.client_secret
  litellm_mcp_url                  = "http://litellm.infra.svc.cluster.local:4000/mcp"

  # Media stack migration
  nfs_server_ip       = local.vm.nfs.ip.vyos
  rotating_proxy_addr = "${local.vm.home_gateway_stack.ip}:${local.vm.home_gateway_stack.ports.rotating_proxy}"

  depends_on = [talos_cluster_kubeconfig.this]
}
