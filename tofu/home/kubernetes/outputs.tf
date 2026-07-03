# =============================================================================
# Module Outputs
# =============================================================================

output "cilium_version" {
  description = "Installed Cilium version"
  value       = helm_release.cilium.version
}

output "system_namespace" {
  description = "System namespace for platform components"
  value       = module.namespace["system"].name
}

output "storage_class" {
  description = "Default storage class name"
  value       = kubernetes_storage_class_v1.ceph_rbd.metadata[0].name
}

output "knative_serving_version" {
  description = "Installed Knative Serving version"
  value       = local.knative_version
}

output "knative_domain" {
  description = "Domain for Knative services"
  value       = local.knative_domain
}

output "otel_daemonset_service" {
  description = "OTLP endpoint for apps to send telemetry (within cluster)"
  value       = "otel-daemonset-opentelemetry-collector.${module.namespace["system"].name}.svc.cluster.local:4317"
}

output "otel_endpoint_external" {
  description = "External OTLP endpoint (monitoring stack)"
  value       = local.otlp_endpoint
}

output "metrics_server_version" {
  description = "Installed Metrics Server version"
  value       = helm_release.metrics_server.version
}

output "openwebui_url" {
  description = "OpenWebUI public URL via Gateway API"
  value       = "https://${local.openwebui_host}"
}

output "hermes_urls" {
  description = "Hermes Agent public URLs via Gateway API"
  value       = { for name, agent in local.hermes_agents : name => "https://${agent.host}" }
}

output "hermes_dashboard_urls" {
  description = "Hermes Agent dashboard URLs via Gateway API"
  value       = { for name, agent in local.hermes_agents : name => "https://${agent.dashboard_host}" }
}

output "vcluster_seven30_version" {
  description = "Installed vcluster version for Seven30 studio"
  value       = helm_release.vcluster_seven30.version
}

output "vcluster_seven30_namespace" {
  description = "Host namespace for Seven30 vcluster"
  value       = local.vcluster_namespace
}

output "gitlab_runner_namespace" {
  description = "Namespace hosting the Kubernetes GitLab runner"
  value       = module.namespace["gitlab-runner"].name
}

output "coder_url" {
  description = "Coder public URL via Gateway API"
  value       = "https://${local.coder_host}"
}

output "mux_url" {
  description = "Mux public URL via Gateway API"
  value       = "https://${local.mux_host}"
}

output "goldilocks_url" {
  description = "Goldilocks resource recommendation dashboard URL"
  value       = "https://goldilocks.home.shdr.ch"
}

output "goldilocks_version" {
  description = "Installed Goldilocks chart version"
  value       = helm_release.goldilocks.version
}

output "vpa_recommender_version" {
  description = "Installed VPA chart version"
  value       = helm_release.vpa_recommender.version
}

output "tetragon_version" {
  description = "Installed Tetragon chart version"
  value       = helm_release.tetragon.version
}

output "trivy_operator_version" {
  description = "Installed Trivy Operator chart version"
  value       = helm_release.trivy_operator.version
}

output "policy_reporter_url" {
  description = "Policy Reporter UI URL"
  value       = "https://${local.policy_reporter_host}"
}

output "policy_reporter_version" {
  description = "Installed Policy Reporter chart version"
  value       = helm_release.policy_reporter.version
}

output "kepler_version" {
  description = "Installed Kepler chart version"
  value       = helm_release.kepler.version
}
