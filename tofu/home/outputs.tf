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

output "dokku_password" {
  value     = random_password.dokku_console_password.result
  sensitive = true
}

output "dokku_deployment_public_key" {
  value = tls_private_key.dokku_deployment_ssh_key.public_key_openssh
}

output "dokku_deployment_private_key" {
  value     = tls_private_key.dokku_deployment_ssh_key.private_key_pem
  sensitive = true
}

output "seaweedfs_password" {
  value     = random_password.seaweedfs_password.result
  sensitive = true
}

output "keycloak_grafana_client_secret" {
  value     = keycloak_openid_client.grafana.client_secret
  sensitive = true
}

output "keycloak_openwebui_client_secret" {
  value     = keycloak_openid_client.openwebui.client_secret
  sensitive = true
}

output "keycloak_gitlab_client_secret" {
  value     = keycloak_openid_client.gitlab.client_secret
  sensitive = true
}

output "smallweb_password" {
  value     = random_password.smallweb_password.result
  sensitive = true
}
