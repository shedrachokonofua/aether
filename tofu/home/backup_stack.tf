resource "proxmox_virtual_environment_container" "backup_stack" {
  vm_id       = local.vm.backup_stack.id
  node_name   = local.vm.backup_stack.node
  description = "Backup stack"

  cpu {
    cores = local.vm.backup_stack.cores
  }

  memory {
    dedicated = local.vm.backup_stack.memory
  }

  network_interface {
    name = "eth0"
  }

  disk {
    datastore_id = "zfs-nvme-vm-dataset"
    size         = local.vm.backup_stack.disk_gb
  }

  mount_point {
    volume = "/mnt/nvme/personal"
    path   = "/mnt/nvme/personal"
  }

  mount_point {
    volume = "/mnt/nvme/data"
    path   = "/mnt/nvme/data"
  }

  mount_point {
    volume = "/mnt/nvme/vm"
    path   = "/mnt/nvme/vm"
  }

  mount_point {
    volume = "/mnt/hdd/data"
    path   = "/mnt/hdd/data"
  }

  mount_point {
    volume = "/mnt/hdd/backups-data"
    path   = "/mnt/hdd/backups-data"
  }

  mount_point {
    volume = "/mnt/hdd/backups-vm"
    path   = "/mnt/hdd/backups-vm"
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.debian_lxc_template.id
    type             = "debian"
  }

  initialization {
    hostname = local.vm.backup_stack.name

    ip_config {
      ipv4 {
        address = "${local.vm.backup_stack.ip}/24"
        gateway = local.vm.backup_stack.gateway
      }
    }

    user_account {
      keys     = var.authorized_keys
      password = random_password.backup_stack_password.result
    }
  }

  features {
    nesting = true
  }
}

resource "random_password" "backup_stack_password" {
  length = 8
}
