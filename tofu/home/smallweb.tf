resource "proxmox_virtual_environment_container" "smallweb" {
  vm_id       = local.vm.smallweb.id
  node_name   = local.vm.smallweb.node
  description = "Smallweb"

  cpu {
    cores = local.vm.smallweb.cores
  }

  memory {
    dedicated = local.vm.smallweb.memory
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    size         = local.vm.smallweb.disk_gb
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.fedora_lxc_template.id
    type             = "fedora"
  }

  initialization {
    hostname = local.vm.smallweb.name

    ip_config {
      ipv4 {
        address = "${local.vm.smallweb.ip}/24"
        gateway = local.vm.smallweb.gateway
      }
    }

    dns {
      servers = [local.vm.smallweb.gateway]
    }

    user_account {
      keys     = var.authorized_keys
      password = random_password.smallweb_password.result
    }
  }

  features {
    nesting = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [operating_system[0].template_file_id, initialization[0].user_account[0].keys]
  }
}

resource "random_password" "smallweb_password" {
  length = 8
}

resource "proxmox_virtual_environment_haresource" "smallweb" {
  resource_id  = "ct:${proxmox_virtual_environment_container.smallweb.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}

