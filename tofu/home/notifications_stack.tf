# Formerly messaging-stack — renamed in place (same vmid 1016) after Matrix
# moved to the Talos cluster. Hosts ntfy + postfix (SES relay) + apprise on
# VLAN 2 (Infrastructure). See docs/worklogs/messaging-stack-migration.md.

moved {
  from = proxmox_virtual_environment_vm.messaging_stack
  to   = proxmox_virtual_environment_vm.notifications_stack
}

moved {
  from = random_password.messaging_stack_console_password
  to   = random_password.notifications_stack_console_password
}

moved {
  from = module.messaging_stack_user
  to   = module.notifications_stack_user
}

moved {
  from = proxmox_virtual_environment_haresource.messaging_stack
  to   = proxmox_virtual_environment_haresource.notifications_stack
}

resource "proxmox_virtual_environment_vm" "notifications_stack" {
  vm_id       = local.vm.notifications_stack.id
  name        = local.vm.notifications_stack.name
  node_name   = local.vm.notifications_stack.node
  description = "Notifications Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.notifications_stack.cores
  }

  memory {
    dedicated = local.vm.notifications_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 2
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.notifications_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    datastore_id = "ceph-vm-disks"

    ip_config {
      ipv4 {
        address = "${local.vm.notifications_stack.ip}/24"
        gateway = local.vm.notifications_stack.gateway
      }
    }

    dns {
      servers = [local.vm.notifications_stack.gateway]
    }

    user_data_file_id = module.notifications_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id, node_name]
  }
}

resource "random_password" "notifications_stack_console_password" {
  length = 8
}

module "notifications_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.notifications_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.notifications_stack.name
  console_password = random_password.notifications_stack_console_password.result
}

resource "proxmox_virtual_environment_haresource" "notifications_stack" {
  resource_id  = "vm:${proxmox_virtual_environment_vm.notifications_stack.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}
