# IDS Stack - Intrusion Detection System (NixOS)
# Suricata (NIDS) + Zeek (protocol analysis) + Wazuh Manager (HIDS)
#
# Network Configuration:
#   - eth0: Management interface on Infrastructure VLAN (10.0.2.7)
#   - eth1: Span port for mirrored traffic from VyOS router (promiscuous mode)
#
# VyOS mirror config (applied separately):
#   set interfaces ethernet eth1 mirror ingress eth2
#   set interfaces ethernet eth1 mirror egress eth2
#
# Machine certificate is pre-provisioned via Terraform from step-ca.
# After provisioning, deploy NixOS config:
#   task configure:ids-stack

# NixOS cloud-config with machine certificate for OpenBao cert auth
module "ids_stack_cloud_config" {
  source = "./modules/nixos_cloud_config"

  name                 = local.vm.ids_stack.name
  ip_addresses         = [local.vm.ids_stack.ip]
  node_name            = local.vm.ids_stack.node
  provisioner_password = var.secrets["step_ca.provisioner_password"]
}

resource "proxmox_virtual_environment_vm" "ids_stack" {
  vm_id       = local.vm.ids_stack.id
  name        = local.vm.ids_stack.name
  node_name   = local.vm.ids_stack.node
  description = "IDS Stack - Suricata + Zeek + Wazuh Manager"

  stop_on_destroy = true

  cpu {
    cores = local.vm.ids_stack.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.ids_stack.memory
  }

  # eth0: Management interface on Infrastructure VLAN
  network_device {
    bridge  = "vmbr0"
    vlan_id = 2
  }

  # eth1: Span port for mirrored traffic from VyOS eth2
  # Isolated bridge - only VyOS and IDS Stack are connected
  # Created by: ansible-playbook ansible/playbooks/home_router/create_mirror_bridge.yml
  network_device {
    bridge   = "vmbr_mirror"
    firewall = false
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = local.nixos_vm_image
    size         = local.vm.ids_stack.disk_gb
    interface    = "virtio0"
  }

  # NixOS base image has cloud-init for initial network config
  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.ids_stack.ip}/24"
        gateway = local.vm.ids_stack.gateway
      }
    }

    dns {
      servers = [local.vm.ids_stack.gateway]
    }

    user_data_file_id = module.ids_stack_cloud_config.file_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

# =============================================================================
# OpenBao Secrets
# =============================================================================
# Synced from SOPS → OpenBao KV → vault-agent on VM

resource "vault_kv_secret_v2" "wazuh" {
  mount = vault_mount.kv.path
  name  = "aether/wazuh"

  data_json = jsonencode({
    indexer_password   = var.secrets["wazuh.indexer_password"]
    api_password       = var.secrets["wazuh.api_password"]
    dashboard_password = var.secrets["wazuh.dashboard_password"]
  })
}
