resource "proxmox_virtual_environment_vm" "lute" {
  vm_id       = local.vm.lute.id
  name        = local.vm.lute.name
  node_name   = local.vm.lute.node
  description = "Lute"

  stop_on_destroy = true

  cpu {
    cores = local.vm.lute.cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.lute.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 3
  }

  disk {
    datastore_id = "nfs-nvme-vm-dataset"
    file_id      = proxmox_virtual_environment_download_file.fedora_image.id
    size         = local.vm.lute.disk_gb
    interface    = "virtio0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.lute.ip}/24"
        gateway = local.vm.lute.gateway
      }
    }

    dns {
      servers = [local.vm.lute.gateway]
    }

    user_data_file_id = module.lute_user.cloud_config_id
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "random_password" "lute_password" {
  length = 8
}

resource "tls_private_key" "lute_ssh_key" {
  algorithm = "ED25519"
}

module "lute_user" {
  username  = local.vm.lute.admin
  source    = "./modules/vm_user_cloudinit"
  node_name = local.vm.lute.node
  authorized_keys = concat(
    [tls_private_key.lute_ssh_key.public_key_openssh],
    var.authorized_keys
  )
  file_prefix      = local.vm.lute.name
  console_password = random_password.lute_password.result
}
