resource "proxmox_virtual_environment_vm" "management_vm" {
  name        = "management-vm"
  node_name   = "trinity"
  description = "Management VM"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = 80
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = module.management_vm_user.cloud_config_id
  }
}

module "management_vm_user" {
  source          = "./modules/vm_user_cloudinit"
  node_name       = "trinity"
  authorized_keys = var.authorized_keys
  password        = var.management_vm_password
}
