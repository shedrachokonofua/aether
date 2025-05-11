resource "proxmox_virtual_environment_vm" "gitlab" {
  vm_id       = local.vm.gitlab.id
  name        = local.vm.gitlab.name
  node_name   = local.vm.gitlab.node
  description = "Gitlab"

  stop_on_destroy = true

  cpu {
    cores = local.vm.gitlab.cores
  }

  memory {
    dedicated = local.vm.gitlab.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.gitlab.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.gitlab.ip}/24"
        gateway = local.vm.gitlab.gateway
      }
    }

    user_data_file_id = module.gitlab_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
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
