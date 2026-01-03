resource "proxmox_virtual_environment_vm" "monitoring_stack" {
  vm_id       = local.vm.monitoring_stack.id
  name        = local.vm.monitoring_stack.name
  node_name   = local.vm.monitoring_stack.node
  description = "Monitoring Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.monitoring_stack.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.monitoring_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 2
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.niobe_fedora_image.id
    size         = local.vm.monitoring_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.monitoring_stack.ip}/24"
        gateway = local.vm.monitoring_stack.gateway
      }
    }

    dns {
      servers = [local.vm.monitoring_stack.gateway]
    }

    user_data_file_id = module.monitoring_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

resource "random_password" "monitoring_stack_console_password" {
  length = 8
}

module "monitoring_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.monitoring_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.monitoring_stack.name
  console_password = random_password.monitoring_stack_console_password.result
}
