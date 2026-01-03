resource "proxmox_virtual_environment_vm" "iot_management_stack" {
  vm_id       = local.vm.iot_management_stack.id
  name        = local.vm.iot_management_stack.name
  node_name   = local.vm.iot_management_stack.node
  description = "IoT Management Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.iot_management_stack.cores
  }

  memory {
    dedicated = local.vm.iot_management_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
    trunks  = "3;4;5;6;7"
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.iot_management_stack.disk_gb
    interface    = "virtio0"
  }

  usb {
    host = "10c4:ea60"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.iot_management_stack.ip}/24"
        gateway = local.vm.iot_management_stack.gateway
      }
    }

    dns {
      servers = [local.vm.iot_management_stack.gateway]
    }

    user_data_file_id = module.iot_management_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

resource "random_password" "iot_management_stack_console_password" {
  length = 8
}

module "iot_management_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.iot_management_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.iot_management_stack.name
  console_password = random_password.iot_management_stack_console_password.result
}
