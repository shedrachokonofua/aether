# cloud-audit — read-only audit role for vigil (PLAN.md §2)
#
# Trust: the Keycloak OIDC provider above, pinned to aud=cloud-audit AND the
# cloud-audit client's service-account sub (identical on both KC auth paths —
# federated-jwt or client-secret — since both mint the service account's token).
# Policy: exactly the read-only audit actions vigil calls, never a managed policy.

variable "keycloak_cloud_audit_sub" {
  type        = string
  description = "Keycloak sub of the cloud-audit client's service-account user (module.home output cloud_audit_fallback_sub)"
}

resource "aws_iam_role" "cloud_audit" {
  name        = "aether-cloud-audit"
  description = "Read-only control-plane audit access for the vigil forwarder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.keycloak.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          "ForAnyValue:StringEquals" = {
            "auth.shdr.ch/realms/aether:aud" = "cloud-audit"
          }
          StringEquals = {
            "auth.shdr.ch/realms/aether:sub" = var.keycloak_cloud_audit_sub
          }
        }
      }
    ]
  })

  max_session_duration = 3600 # 1h

  tags = {
    Name = "aether-cloud-audit"
  }
}

resource "aws_iam_role_policy" "cloud_audit_read" {
  name = "aether-cloud-audit-read"
  role = aws_iam_role.cloud_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AuditReads"
        Effect = "Allow"
        Action = [
          "cloudtrail:LookupEvents",
          "access-analyzer:ListFindings",
          "access-analyzer:ListFindingsV2",
          "access-analyzer:ListAnalyzers",
          "ses:GetSendStatistics",
          "ses:GetAccount",
        ]
        Resource = "*"
      }
    ]
  })
}

output "cloud_audit_role_arn" {
  value       = aws_iam_role.cloud_audit.arn
  description = "Role vigil assumes via AssumeRoleWithWebIdentity (vigil [aws] role_arn)"
}
