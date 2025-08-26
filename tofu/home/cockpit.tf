resource "proxmox_virtual_environment_vm" "cockpit" {
  vm_id       = local.vm.cockpit.id
  name        = local.vm.cockpit.name
  node_name   = local.vm.cockpit.node
  description = "Cockpit"

  stop_on_destroy = true

  cpu {
    cores = local.vm.cockpit.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.cockpit.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 2
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.cockpit.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.cockpit.ip}/24"
        gateway = local.vm.cockpit.gateway
      }
    }

    dns {
      servers = [local.vm.cockpit.gateway]
    }

    user_data_file_id = module.cockpit_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_data_file_id]
  }
}

resource "random_password" "cockpit_password" {
  length = 8
}

module "cockpit_user" {
  username         = local.vm.cockpit.admin
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.cockpit.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.cockpit.name
  console_password = random_password.cockpit_password.result
}
