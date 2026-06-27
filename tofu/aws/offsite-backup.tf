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

  # Allow sessions up to 12 hours (43200 seconds), the IAM role maximum.
  max_session_duration = 43200

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
        Sid      = "AllowListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
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

  # 12 hour sessions (43200 seconds)
  duration_seconds = 43200

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
    # Enabled so accidental or automated deletes create recoverable noncurrent
    # versions instead of immediately erasing the only offsite copy.
    status = "Enabled"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "offsite_backup_lifecycle" {
  bucket = aws_s3_bucket.offsite_backup.id

  rule {
    id     = "DeepArchiveResticData"
    status = "Enabled"

    filter {
      prefix = "restic/data/"
    }

    # Cost: ~$0.00099/GB/month | Retrieval: 12-48 hours, ~$0.02/GB
    # Only restic data packs transition. Repository metadata such as config,
    # snapshots, locks, keys, and index must stay readable for future backups.
    transition {
      days          = 1
      storage_class = "DEEP_ARCHIVE"
    }

    # No expiration: this bucket is the disaster-recovery copy. Retention is
    # controlled by the backup tool and explicit operator action, not by S3
    # lifecycle expiry.
  }

  rule {
    id     = "DeepArchiveResticV2Data"
    status = "Enabled"

    filter {
      prefix = "restic-v2/data/"
    }

    transition {
      days          = 1
      storage_class = "DEEP_ARCHIVE"
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
