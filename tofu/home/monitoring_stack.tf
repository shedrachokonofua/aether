resource "proxmox_virtual_environment_vm" "monitoring_stack" {
  vm_id       = local.vm.monitoring_stack.id
  name        = local.vm.monitoring_stack.name
  node_name   = local.vm.monitoring_stack.node
  description = "Monitoring Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.monitoring_stack.cores
  }

  memory {
    dedicated = local.vm.monitoring_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
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
        address = "${local.vm.monitoring_stack.ip.vyos}/24"
        gateway = local.vm.monitoring_stack.gateway.vyos
      }
    }

    dns {
      servers = [local.vm.monitoring_stack.gateway.vyos]
    }

    user_data_file_id = module.monitoring_stack_user.cloud_config_id
  }
}

module "monitoring_stack_user" {
  source          = "./modules/vm_user_cloudinit"
  node_name       = local.vm.monitoring_stack.node
  authorized_keys = var.authorized_keys
  file_prefix     = local.vm.monitoring_stack.name
  password =  "aether"
}
