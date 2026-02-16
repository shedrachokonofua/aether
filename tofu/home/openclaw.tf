# OpenClaw - Self-hosted AI Assistant (NixOS VM)
# Personal conversational AI with Matrix integration and WebChat UI
#
# Services:
#   - OpenClaw (Podman): AI assistant gateway + agent runtime
#   - vault-agent: Secrets from OpenBao (LiteLLM key, Matrix token, gateway token)
#   - step-ca: Machine certificate auto-renewal
#
# Access:
#   - WebChat UI: openclaw.home.shdr.ch (Caddy → :18789)
#   - Matrix: DM channel via Synapse
#   - LLM: via LiteLLM gateway (litellm.home.shdr.ch)
#
# Deploy NixOS config after provisioning:
#   task configure:openclaw

# NixOS cloud-config with machine certificate for OpenBao cert auth
module "openclaw_cloud_config" {
  source = "./modules/nixos_cloud_config"

  name                 = local.vm.openclaw.name
  ip_addresses         = [local.vm.openclaw.ip]
  node_name            = local.vm.openclaw.node
  provisioner_password = var.secrets["step_ca.provisioner_password"]
}

resource "proxmox_virtual_environment_vm" "openclaw" {
  vm_id       = local.vm.openclaw.id
  name        = local.vm.openclaw.name
  node_name   = local.vm.openclaw.node
  description = "OpenClaw - Self-hosted AI Assistant"

  stop_on_destroy = true

  cpu {
    cores = local.vm.openclaw.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.openclaw.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = local.nixos_vm_image
    file_format  = "raw"
    size         = local.vm.openclaw.disk_gb
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
  }

  initialization {
    datastore_id = "ceph-vm-disks"

    ip_config {
      ipv4 {
        address = "${local.vm.openclaw.ip}/24"
        gateway = local.vm.openclaw.gateway
      }
    }

    dns {
      servers = [local.vm.openclaw.gateway]
    }

    user_data_file_id = module.openclaw_cloud_config.file_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

# HA — Ceph-backed, any node can run this
resource "proxmox_virtual_environment_haresource" "openclaw" {
  resource_id  = "vm:${proxmox_virtual_environment_vm.openclaw.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}

# =============================================================================
# OpenBao Secrets
# =============================================================================
# Placeholder secret — real values injected manually via:
#   bao kv put kv/aether/openclaw \
#     litellm_api_key="sk-..." \
#     matrix_access_token="syt_..." \
#     gateway_token="$(openssl rand -hex 32)" \
#     openrouter_api_key="sk-or-..."
#
# After initial put, Terraform ignores the values (lifecycle ignore).

resource "random_password" "openclaw_gateway_token" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "openclaw" {
  mount = vault_mount.kv.path
  name  = "aether/openclaw"

  data_json = jsonencode({
    gateway_token       = random_password.openclaw_gateway_token.result
    litellm_api_key     = var.secrets["litellm.virtual_keys.openclaw"]
    matrix_access_token = "REPLACE_WITH_MATRIX_TOKEN"
    openrouter_api_key  = var.secrets["litellm.openrouter_api_key"]
  })
}
