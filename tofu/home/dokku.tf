resource "proxmox_virtual_environment_vm" "dokku" {
  vm_id       = local.vm.dokku.id
  name        = local.vm.dokku.name
  node_name   = local.vm.dokku.node
  description = "Dokku"

  stop_on_destroy = true

  cpu {
    cores = local.vm.dokku.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.dokku.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "ceph-vm-disks"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.dokku.disk_gb
    interface    = "virtio0"
  }

  initialization {
    datastore_id = "ceph-vm-disks"

    ip_config {
      ipv4 {
        address = "${local.vm.dokku.ip}/24"
        gateway = local.vm.dokku.gateway
      }
    }

    dns {
      servers = [local.vm.dokku.gateway]
    }

    user_data_file_id = module.dokku_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}

resource "random_password" "dokku_console_password" {
  length = 8
}

resource "tls_private_key" "dokku_deployment_ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

module "dokku_user" {
  source           = "./modules/vm_user_cloudinit"
  node_name        = local.vm.dokku.node
  authorized_keys  = var.authorized_keys
  file_prefix      = local.vm.dokku.name
  console_password = random_password.dokku_console_password.result
}

resource "proxmox_virtual_environment_haresource" "dokku" {
  resource_id  = "vm:${proxmox_virtual_environment_vm.dokku.vm_id}"
  state        = "started"
  group        = proxmox_virtual_environment_hagroup.ceph_workloads.group
  max_restart  = 3
  max_relocate = 2
}

