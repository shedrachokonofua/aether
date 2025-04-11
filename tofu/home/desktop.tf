resource "proxmox_virtual_environment_vm" "desktop" {
  vm_id       = local.vm.desktop.id
  name        = local.vm.desktop.name
  node_name   = local.vm.desktop.node
  description = "Desktop"

  machine = "q35"

  cpu {
    cores = local.vm.desktop.cores
  }

  memory {
    dedicated = local.vm.desktop.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.desktop.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.desktop.ip}/24"
        gateway = local.vm.desktop.gateway
      }
    }

    user_data_file_id = module.desktop_user.cloud_config_id
  }

  # GPU Passthrough
  hostpci {
    device = "hostpci0"
    id     = "0000:e5:00.0"
    pcie   = true
  }
}

module "desktop_user" {
  source           = "./modules/vm_user_cloudinit"
  username         = local.vm.desktop.admin
  node_name        = local.vm.desktop.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.desktop.name
  console_password = var.desktop_password
}
