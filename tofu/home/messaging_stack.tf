resource "proxmox_virtual_environment_vm" "messaging_stack" {
  vm_id       = local.vm.messaging_stack.id
  name        = local.vm.messaging_stack.name
  node_name   = local.vm.messaging_stack.node
  description = "Messaging Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.messaging_stack.cores
  }

  memory {
    dedicated = local.vm.messaging_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.messaging_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    datastore_id = "ceph-vm-disks"

    ip_config {
      ipv4 {
        address = "${local.vm.messaging_stack.ip}/24"
        gateway = local.vm.messaging_stack.gateway
      }
    }

    dns {
      servers = [local.vm.messaging_stack.gateway]
    }

    user_data_file_id = module.messaging_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

resource "random_password" "messaging_stack_console_password" {
  length = 8
}

module "messaging_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.messaging_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.messaging_stack.name
  console_password = random_password.messaging_stack_console_password.result
}

resource "proxmox_virtual_environment_haresource" "messaging_stack" {
  resource_id  = "vm:${proxmox_virtual_environment_vm.messaging_stack.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}
