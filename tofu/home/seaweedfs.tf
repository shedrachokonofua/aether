resource "proxmox_virtual_environment_container" "seaweedfs" {
  vm_id       = local.vm.seaweedfs.id
  node_name   = local.vm.seaweedfs.node
  description = "SeaweedFS - Object storage with S3 API, IAM, WebDAV, Filer"

  cpu {
    cores = local.vm.seaweedfs.cores
  }

  memory {
    dedicated = local.vm.seaweedfs.memory
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = 2
  }

  disk {
    datastore_id = "zfs-nvme-vm-dataset"
    size         = local.vm.seaweedfs.disk_gb
  }

  # NVME mount for hot tier data + metadata
  mount_point {
    volume = "/mnt/nvme/seaweedfs"
    path   = "/mnt/nvme/seaweedfs"
  }

  # HDD mount for cold tier data
  mount_point {
    volume = "/mnt/hdd/seaweedfs"
    path   = "/mnt/hdd/seaweedfs"
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.fedora_lxc_template.id
    type             = "fedora"
  }

  initialization {
    hostname = local.vm.seaweedfs.name

    ip_config {
      ipv4 {
        address = "${local.vm.seaweedfs.ip}/24"
        gateway = local.vm.seaweedfs.gateway
      }
    }

    dns {
      servers = [local.vm.seaweedfs.gateway]
    }

    user_account {
      keys     = var.authorized_keys
      password = random_password.seaweedfs_password.result
    }
  }

  features {
    nesting = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initialization[0].user_account[0].keys]
  }
}

resource "random_password" "seaweedfs_password" {
  length = 8
}

