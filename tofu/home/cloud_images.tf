resource "proxmox_virtual_environment_download_file" "fedora_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "trinity"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name    = "fedora-41.qcow2.img"
}

resource "proxmox_virtual_environment_download_file" "opnsense_image" {
  content_type            = "iso"
  datastore_id            = "local"
  node_name               = "trinity"
  url                     = "https://github.com/maurice-w/opnsense-vm-images/releases/download/25.1/OPNsense-25.1-ufs-serial-vm-amd64.qcow2.bz2"
  decompression_algorithm = "bz2"
  file_name               = "opnsense-25.1.qcow2.img"
  overwrite               = false # Decompression will cause size comparison to fail and the vm to be recreated though the file is the same
}
