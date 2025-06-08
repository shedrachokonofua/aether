resource "proxmox_virtual_environment_vm" "dev_workstation" {
  vm_id       = local.vm.dev_workstation.id
  name        = local.vm.dev_workstation.name
  node_name   = local.vm.dev_workstation.node
  description = "Dev Workstation"

  stop_on_destroy = true

  cpu {
    cores = local.vm.dev_workstation.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.dev_workstation.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.dev_workstation.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.dev_workstation.ip}/24"
        gateway = local.vm.dev_workstation.gateway
      }
    }

    user_data_file_id = module.dev_workstation_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "random_password" "dev_workstation_password" {
  length = 8
}

module "dev_workstation_user" {
  username         = local.vm.dev_workstation.admin
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.dev_workstation.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.dev_workstation.name
  console_password = random_password.dev_workstation_password.result
}
