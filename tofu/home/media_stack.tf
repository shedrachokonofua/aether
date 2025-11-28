resource "proxmox_virtual_environment_vm" "media_stack" {
  vm_id       = local.vm.media_stack.id
  name        = local.vm.media_stack.name
  node_name   = local.vm.media_stack.node
  description = "Media Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.media_stack.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.media_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.media_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.media_stack.ip}/24"
        gateway = local.vm.media_stack.gateway
      }
    }

    dns {
      servers = [local.vm.media_stack.gateway]
    }

    user_data_file_id = module.media_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_data_file_id]
  }
}

resource "random_password" "media_stack_console_password" {
  length = 8
}

module "media_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.media_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.media_stack.name
  console_password = random_password.media_stack_console_password.result
}

