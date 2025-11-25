# AWS SES Configuration for email relay
# Domain identity for sending emails

resource "aws_ses_domain_identity" "shdrch" {
  domain = "shdr.ch"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ses_domain_dkim" "shdrch" {
  domain = aws_ses_domain_identity.shdrch.domain
}

# SMTP credentials for Postfix relay
resource "aws_iam_user" "ses_smtp_user" {
  name = "ses-smtp-user"
  path = "/ses/"

  tags = {
    Purpose = "SES SMTP relay for monitoring alerts"
  }
}

resource "aws_iam_user_policy" "ses_smtp_policy" {
  name = "ses-smtp-send"
  user = aws_iam_user.ses_smtp_user.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendRawEmail",
          "ses:SendEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "ses_smtp_user" {
  user = aws_iam_user.ses_smtp_user.name
}

# Output the SMTP credentials
output "ses_smtp_username" {
  description = "SES SMTP username (IAM access key ID)"
  value       = aws_iam_access_key.ses_smtp_user.id
}

output "ses_smtp_password" {
  description = "SES SMTP password (derived from secret access key)"
  value       = aws_iam_access_key.ses_smtp_user.ses_smtp_password_v4
  sensitive   = true
}

output "ses_domain_identity_arn" {
  description = "ARN of the SES domain identity"
  value       = aws_ses_domain_identity.shdrch.arn
}

output "ses_domain_dkim_tokens" {
  description = "DKIM tokens for DNS verification"
  value       = aws_ses_domain_dkim.shdrch.dkim_tokens
}

output "ses_domain_verification_token" {
  description = "Domain verification token for SES"
  value       = aws_ses_domain_identity.shdrch.verification_token
}

