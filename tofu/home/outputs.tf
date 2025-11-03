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
  value = tls_private_key.lute_ssh_key.public_key_openssh
}

output "lute_private_key" {
  value     = tls_private_key.lute_ssh_key.private_key_openssh
  sensitive = true
}

output "cockpit_password" {
  value     = random_password.cockpit_password.result
  sensitive = true
}

output "coupe_password" {
  value     = random_password.coupe_password.result
  sensitive = true
}

output "gpu_workstation_password" {
  value     = random_password.gpu_workstation_console_password.result
  sensitive = true
}

output "ai_tool_stack_password" {
  value     = random_password.ai_tool_stack_console_password.result
  sensitive = true
}

output "iot_management_stack_password" {
  value     = random_password.iot_management_stack_console_password.result
  sensitive = true
}
