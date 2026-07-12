# Generic NixOS remote builder. Build closures here, then copy them to the
# destination VM so production services never compete with Nix evaluation.
module "nix_builder_cloud_config" {
  source = "./modules/nixos_cloud_config"

  name                 = local.vm.nix_builder.name
  ip_addresses         = [local.vm.nix_builder.ip]
  node_name            = local.vm.nix_builder.node
  provisioner_password = var.secrets["step_ca.provisioner_password"]
}

resource "proxmox_virtual_environment_vm" "nix_builder" {
  vm_id       = local.vm.nix_builder.id
  name        = local.vm.nix_builder.name
  node_name   = local.vm.nix_builder.node
  description = "Generic NixOS remote builder"

  stop_on_destroy = true
  on_boot         = false
  started         = false

  cpu {
    cores = local.vm.nix_builder.cores
    type  = "host"
    units = 512
  }

  memory {
    dedicated = local.vm.nix_builder.memory
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = local.vm.nix_builder.vlan
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = local.nixos_vm_image
    size         = local.vm.nix_builder.disk_gb
    interface    = "virtio0"
    discard      = "on"
    iothread     = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.vm.nix_builder.ip}/24"
        gateway = local.vm.nix_builder.gateway
      }
    }

    dns {
      servers = [local.vm.nix_builder.gateway]
    }

    user_data_file_id = module.nix_builder_cloud_config.file_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].file_id, initialization[0].user_data_file_id]
  }
}
