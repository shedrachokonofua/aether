# =============================================================================
# Module Outputs
# =============================================================================

output "cilium_version" {
  description = "Installed Cilium version"
  value       = helm_release.cilium.version
}

output "system_namespace" {
  description = "System namespace for platform components"
  value       = kubernetes_namespace_v1.system.metadata[0].name
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
  value       = "otel-daemonset-opentelemetry-collector.${kubernetes_namespace_v1.system.metadata[0].name}.svc.cluster.local:4317"
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

output "vcluster_seven30_version" {
  description = "Installed vcluster version for Seven30 studio"
  value       = helm_release.vcluster_seven30.version
}

output "vcluster_seven30_namespace" {
  description = "Host namespace for Seven30 vcluster"
  value       = local.vcluster_namespace
}
