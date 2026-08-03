# =============================================================================
# Siren — object storage
# =============================================================================
# Namespace contract lives in namespace_contracts.tf. The app deploys itself
# from its own repo CI; aether owns only the namespace, the scoped SeaweedFS
# identity (registered in db_backups.tf seaweedfs-s3.json), and the buckets.
# Push identity changes with `task seaweedfs:s3-identities:deploy`.

locals {
  siren_namespace      = module.namespace["siren"].name
  siren_s3_endpoint    = "https://s3.seaweed.home.shdr.ch"
  siren_web_bucket     = "siren-web"
  siren_content_bucket = "siren-content"
  siren_backup_bucket  = "siren-backups"
  siren_buckets = [
    local.siren_web_bucket,
    local.siren_content_bucket,
    local.siren_backup_bucket,
  ]
  siren_labels = { app = "siren" }
}

resource "random_password" "siren_s3_access_key" {
  length  = 20
  special = false
}

resource "random_password" "siren_s3_secret_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "siren_object_store" {
  depends_on = [module.namespace["siren"]]

  metadata {
    name      = "siren-s3"
    namespace = local.siren_namespace
    labels    = local.siren_labels
  }

  type = "Opaque"
  data = {
    AWS_ACCESS_KEY_ID     = random_password.siren_s3_access_key.result
    AWS_SECRET_ACCESS_KEY = random_password.siren_s3_secret_key.result
    AWS_DEFAULT_REGION    = "us-east-1"
  }
}

# Identity for keyless web publishes: Siren CI mints a short-lived token for
# this ServiceAccount through the GitLab agent, exchanges it at the SeaweedFS
# STS gateway for the SirenWebPublisher role (db_backups.tf), and syncs the
# static site. No standing credential exists anywhere in that path.
resource "kubernetes_service_account_v1" "siren_publisher" {
  metadata {
    name      = "siren-publisher"
    namespace = local.siren_namespace
    labels    = local.siren_labels
  }
}

resource "terraform_data" "siren_buckets" {
  triggers_replace = [join(",", local.siren_buckets)]

  provisioner "local-exec" {
    command = <<-EOT
      for bucket in $S3_BUCKETS; do
        aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 || \
          aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$bucket" >/dev/null
      done
    EOT
    environment = {
      AWS_ACCESS_KEY_ID         = var.secrets["seaweedfs.s3_admin_access_key"]
      AWS_SECRET_ACCESS_KEY     = var.secrets["seaweedfs.s3_admin_secret_key"]
      AWS_DEFAULT_REGION        = "us-east-1"
      AWS_EC2_METADATA_DISABLED = "true"
      S3_ENDPOINT               = local.siren_s3_endpoint
      S3_BUCKETS                = join(" ", local.siren_buckets)
    }
  }
}
