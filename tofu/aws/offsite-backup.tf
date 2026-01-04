# =============================================================================
# IAM Roles Anywhere (replaces static IAM user credentials)
# Uses step-ca trust anchor provisioned via CloudFormation
# =============================================================================

data "aws_cloudformation_stack" "step_ca_trust" {
  name = "aether-step-ca-trust"
}

resource "aws_iam_role" "offsite_backup" {
  name = "offsite-backup"
  path = "/aether/"

  # Allow sessions up to 8 hours (28800 seconds)
  max_session_duration = 28800

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "rolesanywhere.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
          "sts:SetSourceIdentity"
        ]
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = data.aws_cloudformation_stack.step_ca_trust.outputs["TrustAnchorArn"]
          }
          StringEquals = {
            # Only allow certificates with CN=backup-stack.home.shdr.ch
            "aws:PrincipalTag/x509Subject/CN" = "backup-stack.home.shdr.ch"
          }
        }
      }
    ]
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "offsite_backup" {
  name = "offsite-backup-s3"
  role = aws_iam_role.offsite_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowListBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.offsite_backup.arn]
      },
      {
        Sid    = "AllowObjectActions"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAttributes",
          "s3:RestoreObject"
        ]
        Resource = ["${aws_s3_bucket.offsite_backup.arn}/*"]
      }
    ]
  })
}

resource "aws_rolesanywhere_profile" "offsite_backup" {
  name      = "offsite-backup"
  enabled   = true
  role_arns = [aws_iam_role.offsite_backup.arn]

  # 8 hour sessions (28800 seconds)
  duration_seconds = 28800

  tags = {
    Name    = "offsite-backup"
    Project = "aether"
  }
}

# =============================================================================
# S3 Bucket for offsite backups
# =============================================================================

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

resource "aws_s3_bucket_versioning" "offsite_backup_versioning" {
  bucket = aws_s3_bucket.offsite_backup.id
  versioning_configuration {
    # Disabled - Deep Archive has 180-day minimum storage charge per object,
    # so versioning causes paying for "deleted" versions for 6 months.
    # The source data (PBS/ZFS) already has its own versioning.
    status = "Suspended"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "offsite_backup_lifecycle" {
  bucket = aws_s3_bucket.offsite_backup.id

  rule {
    id     = "DeepArchiveBackups"
    status = "Enabled"

    filter {
      prefix = ""
    }

    # Cost: ~$0.00099/GB/month | Retrieval: 12-48 hours, ~$0.02/GB
    transition {
      days          = 1
      storage_class = "DEEP_ARCHIVE"
    }

    # Auto-delete after 181 days (just past Deep Archive 180-day minimum)
    # You're paying for 180 days regardless, so no point keeping longer unless needed
    expiration {
      days = 181
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  depends_on = [aws_s3_bucket_ownership_controls.offsite_backup_ownership_controls]
}

# =============================================================================
# Outputs
# =============================================================================

output "offsite_backup_bucket_name" {
  value = aws_s3_bucket.offsite_backup.id
}

output "offsite_backup_bucket_arn" {
  value = aws_s3_bucket.offsite_backup.arn
}

output "offsite_backup_role_arn" {
  value = aws_iam_role.offsite_backup.arn
}

output "offsite_backup_profile_arn" {
  value = aws_rolesanywhere_profile.offsite_backup.arn
}

output "offsite_backup_trust_anchor_arn" {
  value = data.aws_cloudformation_stack.step_ca_trust.outputs["TrustAnchorArn"]
}
