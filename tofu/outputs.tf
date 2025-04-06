output "home_gateway_stack_console_password" {
  value     = module.home.gateway_stack_console_password
  sensitive = true
}

output "home_monitoring_stack_console_password" {
  value     = module.home.monitoring_stack_console_password
  sensitive = true
}

output "home_dokploy_console_password" {
  value     = module.home.dokploy_console_password
  sensitive = true
}

output "home_backup_stack_password" {
  value     = module.home.backup_stack_password
  sensitive = true
}

output "aws_lute_minio_backup_user_access_key" {
  value     = module.aws.lute_minio_backup_user_access_key
  sensitive = true
}

output "aws_lute_minio_backup_user_secret_access_key" {
  value     = module.aws.lute_minio_backup_user_secret_access_key
  sensitive = true
}

output "aws_offsite_backup_user_access_key" {
  value     = module.aws.offsite_backup_user_access_key
  sensitive = true
}

output "aws_offsite_backup_user_secret_access_key" {
  value     = module.aws.offsite_backup_user_secret_access_key
  sensitive = true
}

output "aws_offsite_backup_bucket_name" {
  value = module.aws.offsite_backup_bucket_name
}

output "aws_offsite_backup_bucket_arn" {
  value = module.aws.offsite_backup_bucket_arn
}
