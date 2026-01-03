resource "proxmox_virtual_environment_vm" "dokploy" {
  vm_id       = local.vm.dokploy.id
  name        = local.vm.dokploy.name
  node_name   = local.vm.dokploy.node
  description = "Dokploy"

  stop_on_destroy = true

  cpu {
    cores = local.vm.dokploy.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.dokploy.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.dokploy.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.dokploy.ip}/24"
        gateway = local.vm.dokploy.gateway
      }
    }

    dns {
      servers = [local.vm.dokploy.gateway]
    }

    user_data_file_id = module.dokploy_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

resource "random_password" "dokploy_console_password" {
  length = 8
}

module "dokploy_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.dokploy.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.dokploy.name
  console_password = random_password.dokploy_console_password.result
}
