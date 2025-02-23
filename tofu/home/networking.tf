resource "proxmox_virtual_environment_vm" "router" {
  name        = "router"
  node_name   = "trinity"
  description = "OPNSense Router"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  startup {
    order = 1
  }

  cpu {
    cores = 8
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.opnsense_image.id
    size         = 128
    interface    = "virtio0"
  }

  # WAN
  network_device {
    bridge = "vmbr0"
  }

  # LAN
  network_device {
    bridge = "vmbr0"
  }
}

resource "proxmox_virtual_environment_vm" "router_setup_bastion" {
  name        = "router-setup-bastion"
  node_name   = "trinity"
  description = "Router Setup Bastion"

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = 20
    interface    = "virtio0"
  }

  # WAN
  network_device {
    bridge = "vmbr0"
  }

  # LAN
  network_device {
    bridge = "vmbr0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "192.168.2.240/24"
        gateway = "192.168.2.1"
      }
    }

    ip_config {
      ipv4 {
        address = "192.168.1.2/24"
        gateway = "192.168.1.1" # OpnSense gateway on initial boot
      }
    }

    user_data_file_id = module.router_setup_bastion_vm_user.cloud_config_id
  }
}

module "router_setup_bastion_vm_user" {
  source          = "./modules/vm_user_cloudinit"
  node_name       = "trinity"
  authorized_keys = var.authorized_keys
  password        = var.router_password
  file_prefix     = "router-setup-bastion"
}
