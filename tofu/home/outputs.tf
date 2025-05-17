output "gateway_stack_console_password" {
  value     = random_password.gateway_stack_console_password.result
  sensitive = true
}

output "monitoring_stack_console_password" {
  value     = random_password.monitoring_stack_console_password.result
  sensitive = true
}

output "dokploy_console_password" {
  value     = random_password.dokploy_console_password.result
  sensitive = true
}

output "backup_stack_password" {
  value     = random_password.backup_stack_password.result
  sensitive = true
}

output "dev_workstation_password" {
  value     = random_password.dev_workstation_password.result
  sensitive = true
}

output "lute_password" {
  value     = random_password.lute_password.result
  sensitive = true
}

output "lute_public_key" {
  value     = tls_private_key.lute_ssh_key.public_key_openssh
}

output "lute_private_key" {
  value     = tls_private_key.lute_ssh_key.private_key_openssh
  sensitive = true
}
