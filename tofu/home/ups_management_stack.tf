resource "proxmox_virtual_environment_vm" "ups_management_stack" {
  vm_id       = local.vm.ups_management_stack.id
  name        = local.vm.ups_management_stack.name
  node_name   = local.vm.ups_management_stack.node
  description = "UPS Management Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.ups_management_stack.cores
  }

  memory {
    dedicated = local.vm.ups_management_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 2
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.ups_management_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.ups_management_stack.ip}/24"
        gateway = local.vm.ups_management_stack.gateway
      }
    }

    dns {
      servers = [local.vm.ups_management_stack.gateway]
    }

    user_data_file_id = module.ups_management_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_data_file_id]
  }
}

resource "random_password" "ups_management_stack_console_password" {
  length = 8
}

module "ups_management_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.ups_management_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.ups_management_stack.name
  console_password = random_password.ups_management_stack_console_password.result
}
