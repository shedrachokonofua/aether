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

output "home_dev_workstation_password" {
  value     = module.home.dev_workstation_password
  sensitive = true
}

output "home_dev_workstation_public_key" {
  value = local.home.dev_workstation.public_key
}

output "home_dev_workstation_private_key" {
  value     = local.home.dev_workstation.private_key
  sensitive = true
}

output "home_lute_public_key" {
  value = module.home.lute_public_key
}

output "home_lute_private_key" {
  value     = module.home.lute_private_key
  sensitive = true
}

output "home_cockpit_public_key" {
  value = local.home.cockpit.public_key
}

output "home_cockpit_private_key" {
  value     = local.home.cockpit.private_key
  sensitive = true
}

output "home_cockpit_password" {
  value     = module.home.cockpit_password
  sensitive = true
}

output "ssh_authorized_keys" {
  value = local.authorized_keys
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
