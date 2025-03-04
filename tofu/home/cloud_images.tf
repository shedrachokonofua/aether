resource "proxmox_virtual_environment_download_file" "fedora_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = "trinity"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
  file_name    = "fedora-41.qcow2.img"
}
