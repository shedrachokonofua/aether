resource "proxmox_virtual_environment_vm" "gpu_workstation" {
  vm_id       = local.vm.gpu_workstation.id
  name        = local.vm.gpu_workstation.name
  node_name   = local.vm.gpu_workstation.node
  description = "GPU Workstation"

  stop_on_destroy = true

  cpu {
    cores = local.vm.gpu_workstation.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.gpu_workstation.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.neo_fedora_image.id
    size         = local.vm.gpu_workstation.disk_gb
    interface    = "virtio0"
  }

  hostpci {
    device = "hostpci0"
    id     = "0000:01:00.0"
    xvga   = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.gpu_workstation.ip}/24"
        gateway = local.vm.gpu_workstation.gateway
      }
    }

    dns {
      servers = [local.vm.gpu_workstation.gateway]
    }

    user_data_file_id = module.gpu_workstation_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_data_file_id]
  }
}

resource "random_password" "gpu_workstation_console_password" {
  length = 8
}

module "gpu_workstation_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.gpu_workstation.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.gpu_workstation.name
  console_password = random_password.gpu_workstation_console_password.result
}
