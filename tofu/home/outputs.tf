output "gateway_stack_console_password" {
  value = random_password.gateway_stack_console_password.result
  sensitive = true
}

output "monitoring_stack_console_password" {
  value = random_password.monitoring_stack_console_password.result
  sensitive = true
}
