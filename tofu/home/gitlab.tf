resource "proxmox_virtual_environment_vm" "gitlab" {
  vm_id       = local.vm.gitlab.id
  name        = local.vm.gitlab.name
  node_name   = local.vm.gitlab.node
  description = "Gitlab"

  stop_on_destroy = true

  cpu {
    cores = local.vm.gitlab.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.gitlab.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.gitlab.disk_gb
    interface    = "virtio0"
  }

  initialization {
    datastore_id = "ceph-vm-disks"

    ip_config {
      ipv4 {
        address = "${local.vm.gitlab.ip}/24"
        gateway = local.vm.gitlab.gateway
      }
    }

    dns {
      servers = [local.vm.gitlab.gateway]
    }

    user_data_file_id = module.gitlab_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

resource "random_password" "gitlab_console_password" {
  length = 8
}

module "gitlab_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.gitlab.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.gitlab.name
  console_password = random_password.gitlab_console_password.result
}

resource "proxmox_virtual_environment_haresource" "gitlab" {
  resource_id  = "vm:${proxmox_virtual_environment_vm.gitlab.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}
