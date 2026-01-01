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

output "home_gpu_workstation_public_key" {
  value = local.home.gpu_workstation.public_key
}

output "home_gpu_workstation_private_key" {
  value     = local.home.gpu_workstation.private_key
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

output "aws_public_gateway_ip" {
  value = module.aws.public_gateway_ip
}

output "aws_public_gateway_public_key" {
  value = module.aws.public_gateway_public_key
}

output "aws_public_gateway_private_key" {
  value     = module.aws.public_gateway_private_key
  sensitive = true
}

output "tailscale_public_gateway_oauth_client_id" {
  value = tailscale_oauth_client.public_gateway_oauth_client.id
}

output "tailscale_public_gateway_oauth_client_secret" {
  value     = tailscale_oauth_client.public_gateway_oauth_client.key
  sensitive = true
}

output "aws_ses_smtp_username" {
  value = module.aws.ses_smtp_username
}

output "aws_ses_smtp_password" {
  value     = module.aws.ses_smtp_password
  sensitive = true
}

output "aws_ses_domain_dkim_tokens" {
  value = module.aws.ses_domain_dkim_tokens
}

output "aws_ses_domain_verification_token" {
  value = module.aws.ses_domain_verification_token
}

output "home_dokku_password" {
  value     = module.home.dokku_password
  sensitive = true
}

output "home_dokku_deployment_public_key" {
  value = module.home.dokku_deployment_public_key
}

output "home_dokku_deployment_private_key" {
  value     = module.home.dokku_deployment_private_key
  sensitive = true
}

output "keycloak_grafana_client_secret" {
  value     = module.home.keycloak_grafana_client_secret
  sensitive = true
}

output "keycloak_openwebui_client_secret" {
  value     = module.home.keycloak_openwebui_client_secret
  sensitive = true
}

output "keycloak_gitlab_client_secret" {
  value     = module.home.keycloak_gitlab_client_secret
  sensitive = true
}

# AWS OIDC Federation (for task login)
output "keycloak_oidc_provider_arn" {
  description = "ARN of the Keycloak OIDC identity provider in AWS"
  value       = module.aws.keycloak_oidc_provider_arn
}

output "aws_admin_role_arn" {
  description = "ARN of the admin role for SSO users in AWS"
  value       = module.aws.admin_role_arn
}
