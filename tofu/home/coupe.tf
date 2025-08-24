resource "proxmox_virtual_environment_vm" "coupe" {
  vm_id       = local.vm.coupe.id
  name        = local.vm.coupe.name
  node_name   = local.vm.coupe.node
  description = "Coupe Sandbox"

  stop_on_destroy = true

  cpu {
    cores = local.vm.coupe.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.coupe.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.coupe.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.coupe.ip}/24"
        gateway = local.vm.coupe.gateway
      }
    }

    dns {
      servers = [local.vm.coupe.gateway]
    }

    user_data_file_id = module.coupe_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "random_password" "coupe_password" {
  length = 8
}

module "coupe_user" {
  username         = local.vm.coupe.admin
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.coupe.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.coupe.name
  console_password = random_password.coupe_password.result
}
