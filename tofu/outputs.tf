output "management_vm_password" {
  value     = random_password.management_vm_password.result
  sensitive = true
}

output "management_vm_private_key" {
  value     = tls_private_key.management_vm_key.private_key_pem
  sensitive = true
}

output "management_vm_public_key" {
  value = tls_private_key.management_vm_key.public_key_openssh
}
