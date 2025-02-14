resource "aws_accessanalyzer_analyzer" "unused_access_analyzer" {
  analyzer_name = "unused-access-analyzer"
  type          = "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = 90
    }
  }
}

resource "aws_iam_user" "lute_minio_backup_user" {
  name = "lute-minio-backup-user"
  path = "/aether/"
}

resource "aws_iam_access_key" "lute_minio_backup_user_access_key" {
  user = aws_iam_user.lute_minio_backup_user.name
}

resource "aws_s3_bucket" "lute_backup" {
  bucket = "lute-backup"
}

resource "aws_s3_account_public_access_block" "lute_backup_public_access_block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lute_backup_ownership_controls" {
  bucket = aws_s3_bucket.lute_backup.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

data "aws_iam_policy_document" "lute_backup_policy_document" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lute_backup.arn]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.lute_minio_backup_user.arn]
    }
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.lute_backup.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.lute_minio_backup_user.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "lute_backup_policy" {
  bucket = aws_s3_bucket.lute_backup.id
  policy = data.aws_iam_policy_document.lute_backup_policy_document.json
}

output "aws_lute_minio_backup_user_access_key" {
  value     = aws_iam_access_key.lute_minio_backup_user_access_key.id
  sensitive = true
}

output "aws_lute_minio_backup_user_secret_access_key" {
  value     = aws_iam_access_key.lute_minio_backup_user_access_key.secret
  sensitive = true
}
