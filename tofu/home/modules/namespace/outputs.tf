output "name" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}

output "uid" {
  value = kubernetes_namespace_v1.this.metadata[0].uid
}

output "labels" {
  value = kubernetes_namespace_v1.this.metadata[0].labels
}

output "s3_backup_secret_name" {
  value = try(kubernetes_secret_v1.s3_backup[0].metadata[0].name, null)
}
