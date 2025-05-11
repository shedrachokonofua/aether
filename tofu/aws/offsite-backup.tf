resource "aws_iam_user" "offsite_backup_user" {
  name = "offsite-backup-user"
  path = "/aether/"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_access_key" "offsite_backup_user_access_key" {
  user = aws_iam_user.offsite_backup_user.name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket" "offsite_backup" {
  bucket = "aether-home-offsite-backup"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_account_public_access_block" "offsite_public_access_block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "offsite_backup_ownership_controls" {
  bucket = aws_s3_bucket.offsite_backup.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "offsite_backup_encryption" {
  bucket = aws_s3_bucket.offsite_backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "offsite_backup_lifecycle" {
  bucket = aws_s3_bucket.offsite_backup.id

  rule {
    id     = "TransitionToGlacierFlexibleRetrieval"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 0
      storage_class = "GLACIER"
    }
  }

  depends_on = [aws_s3_bucket_ownership_controls.offsite_backup_ownership_controls]
}

data "aws_iam_policy_document" "offsite_backup_policy_document" {
  statement {
    sid       = "AllowUserListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.offsite_backup.arn]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.offsite_backup_user.arn]
    }
  }

  statement {
    sid = "AllowUserObjectActions"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectAttributes",
      "s3:RestoreObject"
    ]
    resources = ["${aws_s3_bucket.offsite_backup.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.offsite_backup_user.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "offsite_backup_policy" {
  bucket = aws_s3_bucket.offsite_backup.id
  policy = data.aws_iam_policy_document.offsite_backup_policy_document.json

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.offsite_backup_encryption]

  lifecycle {
    prevent_destroy = true
  }
}

output "offsite_backup_user_access_key" {
  value     = aws_iam_access_key.offsite_backup_user_access_key.id
  sensitive = true
}

output "offsite_backup_user_secret_access_key" {
  value     = aws_iam_access_key.offsite_backup_user_access_key.secret
  sensitive = true
}

output "offsite_backup_bucket_name" {
  value = aws_s3_bucket.offsite_backup.id
}

output "offsite_backup_bucket_arn" {
  value = aws_s3_bucket.offsite_backup.arn
}
