resource "tls_private_key" "uptime_monitor_ssh_key" {
  algorithm = "ED25519"
}

resource "local_file" "uptime_monitor_private_key" {
  content         = tls_private_key.uptime_monitor_ssh_key.private_key_openssh
  filename        = "${path.module}/../../secrets/uptime_monitor_private_key.pem"
  file_permission = "0600"
}

resource "google_compute_instance" "uptime_monitor" {
  name                      = "aether-uptime-monitor"
  machine_type              = "e2-micro"
  zone                      = "us-central1-a" # Free Tier zone
  tags                      = ["uptime-monitor"]
  allow_stopping_for_update = true # Allows stopping the VM to apply service account scopes
  desired_status            = "RUNNING" # Forces OpenTofu to keep the VM running/started

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      type  = "pd-standard"  # Free Tier HDD
      size  = 15             # Under 30 GB Free Tier limit
    }
  }

  network_interface {
    network = "default"

    # Assigns an ephemeral public IP (free while VM is active)
    access_config {}
  }

  metadata = {
    ssh-keys        = "debian:${tls_private_key.uptime_monitor_ssh_key.public_key_openssh}"
    enable-osconfig = "true"  # Required for VM Manager
  }

  # Enable VM Service Account scopes for OS Config / monitoring access
  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

output "uptime_monitor_ip" {
  value       = google_compute_instance.uptime_monitor.network_interface[0].access_config[0].nat_ip
  description = "Public IP of the uptime monitor VM"
}

output "uptime_monitor_public_key" {
  value = tls_private_key.uptime_monitor_ssh_key.public_key_openssh
}

output "uptime_monitor_private_key" {
  value     = tls_private_key.uptime_monitor_ssh_key.private_key_openssh
  sensitive = true
}
