resource "proxmox_virtual_environment_vm" "management_vm" {
  name        = "management-vm"
  node_name   = "trinity"
  description = "Management VM"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.fedora_cloud_image.id
    interface    = "virtio0"
    size         = 80
    file_format  = "raw"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      keys     = [trimspace(tls_private_key.management_vm_key.public_key_openssh)]
      password = local.vm_pass
      username = "hello@pam"
    }
  }
}

resource "proxmox_virtual_environment_download_file" "fedora_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "trinity"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name    = "fedora-41.qcow2.img"
}

resource "random_password" "management_vm_password" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "tls_private_key" "management_vm_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
