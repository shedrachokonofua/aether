output "home_gateway_stack_console_password" {
  value = module.home.gateway_stack_console_password
  sensitive = true
}

output "home_monitoring_stack_console_password" {
  value = module.home.monitoring_stack_console_password
  sensitive = true
}

output "aws_lute_minio_backup_user_access_key" {
  value = module.aws.lute_minio_backup_user_access_key
  sensitive = true
}

output "aws_lute_minio_backup_user_secret_access_key" {
  value = module.aws.lute_minio_backup_user_secret_access_key
  sensitive = true
}
