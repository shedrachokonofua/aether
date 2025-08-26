resource "proxmox_virtual_environment_vm" "home_automation_stack" {
  vm_id       = local.vm.home_automation_stack.id
  name        = local.vm.home_automation_stack.name
  node_name   = local.vm.home_automation_stack.node
  description = "Home Automation Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.home_automation_stack.cores
  }

  memory {
    dedicated = local.vm.home_automation_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
    trunks  = "3;4;5;6;7"
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.home_automation_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.home_automation_stack.ip}/24"
        gateway = local.vm.home_automation_stack.gateway
      }
    }

    dns {
      servers = [local.vm.home_automation_stack.gateway]
    }

    user_data_file_id = module.home_automation_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_data_file_id]
  }
}

resource "random_password" "home_automation_stack_console_password" {
  length = 8
}

module "home_automation_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.home_automation_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.home_automation_stack.name
  console_password = random_password.home_automation_stack_console_password.result
}
