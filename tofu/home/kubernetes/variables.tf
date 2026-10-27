variable "grafana_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Grafana Keycloak OIDC client secret"
}
