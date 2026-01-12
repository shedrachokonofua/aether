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
# Cilium Installation
# =============================================================================
# Install Cilium CNI after cluster bootstrap using cilium CLI

resource "null_resource" "install_cilium" {
  depends_on = [data.talos_cluster_health.this]

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Write kubeconfig to temp file
      echo '${talos_cluster_kubeconfig.this.kubeconfig_raw}' > /tmp/talos-kubeconfig

      # Install Cilium with kube-proxy replacement and L2 announcements
      # Talos-specific settings: cgroup mount + explicit capabilities
      KUBECONFIG=/tmp/talos-kubeconfig cilium install \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost=${local.talos_api_vip} \
        --set k8sServicePort=6443 \
        --set l2announcements.enabled=true \
        --set externalIPs.enabled=true \
        --set operator.replicas=1 \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        --set ipam.mode=kubernetes \
        --set gatewayAPI.enabled=true \
        --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
        --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
        --set cgroup.autoMount.enabled=false \
        --set cgroup.hostRoot=/sys/fs/cgroup

      # Wait for Cilium to be ready
      KUBECONFIG=/tmp/talos-kubeconfig cilium status --wait

      # Apply L2 announcement policy and IP pool
      cat <<EOF | KUBECONFIG=/tmp/talos-kubeconfig kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: cluster-ingress
spec:
  interfaces:
    - ^ens[0-9]+
  externalIPs: true
  loadBalancerIPs: true
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: ingress-pool
spec:
  blocks:
    - start: ${local.talos_workload_vip}
      stop: ${local.talos_workload_vip}
---
# RBAC: Map Keycloak 'admin' role to cluster-admin
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: Group
    name: admin
    apiGroup: rbac.authorization.k8s.io
EOF

      # Cleanup
      rm /tmp/talos-kubeconfig
    EOT
  }
}

# =============================================================================
# Gateway API Installation
# =============================================================================
# Installs Gateway API CRDs, upgrades Cilium to enable Gateway controller,
# and creates GatewayClass + Gateway resources

resource "null_resource" "install_gateway_api" {
  depends_on = [null_resource.install_cilium]

  triggers = {
    gateway_api_version = local.gateway_api_version
    cluster_id          = talos_machine_secrets.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo '${talos_cluster_kubeconfig.this.kubeconfig_raw}' > /tmp/talos-kubeconfig
      export KUBECONFIG=/tmp/talos-kubeconfig

      # Install Gateway API CRDs
      kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${local.gateway_api_version}/standard-install.yaml

      # Upgrade Cilium to enable Gateway API controller (idempotent if already enabled)
      cilium upgrade --set gatewayAPI.enabled=true

      # Wait for Cilium to be ready after upgrade
      cilium status --wait

      # Apply GatewayClass and Gateway
      kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: default
  annotations:
    io.cilium/lb-ipam-ips: "${local.talos_workload_vip}"
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.apps.home.shdr.ch"
      allowedRoutes:
        namespaces:
          from: All
EOF

      rm /tmp/talos-kubeconfig
    EOT
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

