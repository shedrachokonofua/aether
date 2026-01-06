resource "proxmox_virtual_environment_vm" "ai_tool_stack" {
  vm_id       = local.vm.ai_tool_stack.id
  name        = local.vm.ai_tool_stack.name
  node_name   = local.vm.ai_tool_stack.node
  description = "AI Tool Stack"

  stop_on_destroy = true

  cpu {
    cores = local.vm.ai_tool_stack.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.ai_tool_stack.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.ai_tool_stack.disk_gb
    interface    = "virtio0"
  }

  initialization {
    datastore_id = "ceph-vm-disks"

    ip_config {
      ipv4 {
        address = "${local.vm.ai_tool_stack.ip}/24"
        gateway = local.vm.ai_tool_stack.gateway
      }
    }

    dns {
      servers = [local.vm.ai_tool_stack.gateway]
    }

    user_data_file_id = module.ai_tool_stack_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

resource "random_password" "ai_tool_stack_console_password" {
  length = 8
}

module "ai_tool_stack_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.ai_tool_stack.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.ai_tool_stack.name
  console_password = random_password.ai_tool_stack_console_password.result
}

resource "proxmox_virtual_environment_haresource" "ai_tool_stack" {
  resource_id  = "vm:${proxmox_virtual_environment_vm.ai_tool_stack.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}
