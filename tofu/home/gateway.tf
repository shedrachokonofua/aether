resource "proxmox_virtual_environment_vm" "gateway_stack" {
  vm_id       = local.vm.gateway_stack.id
  name        = local.vm.gateway_stack.name
  node_name   = local.vm.gateway_stack.node
  description = "Gateway Stack"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  cpu {
    cores = local.vm.gateway_stack.cores
    type  = "host" # Needed for avx support for mongodb
  }

  memory {
    dedicated = local.vm.gateway_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
    trunks  = "3;4;5;6;7"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.oracle_fedora_image.id
    size         = 128
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.gateway_stack.ip.vyos}/24"
        gateway = local.vm.gateway_stack.gateway.vyos
      }
    }

    dns {
      servers = [local.vm.gateway_stack.gateway.vyos]
    }

    user_data_file_id = module.gateway_stack_user.cloud_config_id
  }
}

module "gateway_stack_user" {
  source          = "./modules/vm_user_cloudinit"
  node_name       = "oracle"
  authorized_keys = var.authorized_keys
  password        = "aether"
  file_prefix     = "gateway-stack"
}
