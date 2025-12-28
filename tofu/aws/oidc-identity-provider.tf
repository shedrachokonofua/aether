# OIDC Identity Provider - Keycloak federation for `task login`


resource "aws_iam_openid_connect_provider" "keycloak" {
  url             = "https://auth.shdr.ch/realms/aether"
  client_id_list  = ["toolbox", "openbao"]

  tags = {
    Name = "aether-oidc"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "admin" {
  name        = "aether-admin"
  description = "Admin access for SSO users"

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
            "auth.shdr.ch/realms/aether:aud" = "toolbox"
          }
          StringEquals = {
            "auth.shdr.ch/realms/aether:sub" = var.keycloak_shdrch_sub
          }
        }
      }
    ]
  })

  max_session_duration = 43200 # 12h

  tags = {
    Name = "aether-admin"
  }
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "keycloak_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.keycloak.arn
}

output "admin_role_arn" {
  value = aws_iam_role.admin.arn
}
