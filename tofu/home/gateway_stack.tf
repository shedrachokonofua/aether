resource "proxmox_virtual_environment_vm" "gateway_stack" {
  vm_id       = local.vm.gateway_stack.id
  name        = local.vm.gateway_stack.name
  node_name   = local.vm.gateway_stack.node
  description = "Gateway Stack"

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
    vlan_id = 2
    trunks  = "2;3;4;5;6;7"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.oracle_fedora_image.id
    size         = local.vm.gateway_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.gateway_stack.ip}/24"
        gateway = local.vm.gateway_stack.gateway
      }
    }

    dns {
      servers = [local.vm.gateway_stack.gateway]
    }

    user_data_file_id = module.gateway_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_data_file_id]
  }
}

resource "random_password" "gateway_stack_console_password" {
  length = 8
}

module "gateway_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.gateway_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.gateway_stack.name
  console_password = random_password.gateway_stack_console_password.result
}
