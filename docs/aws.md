# AWS

## Budget

Monthly budget of $15 USD with notifications at 50%, 80%, and 100% of actual costs, plus 100% of forecasted costs.

## Security

Access Analyzers monitor for:

- Unused IAM roles and users with a 90-day unused access threshold
- External access to account resources

## State Management

### OpenTofu Backend

CloudFormation stack providing remote state storage:

- **S3 bucket** - State files with KMS encryption, versioning, delete protection
- **DynamoDB table** - State locking (pay-per-request)
- **KMS key** - Encryption for S3 and DynamoDB
- **Access logs bucket** - S3 access logs archived to Glacier

## Identity

### IAM Roles Anywhere

Trust anchor for step-ca certificates, enabling certificate-based AWS authentication without static credentials.

| Profile             | Role                | Trusted CN       | Permissions         |
| ------------------- | ------------------- | ---------------- | ------------------- |
| openbao-auto-unseal | openbao-auto-unseal | bao.home.shdr.ch | KMS Encrypt/Decrypt |

### KMS Keys

| Key                 | Purpose                            | Rotation |
| ------------------- | ---------------------------------- | -------- |
| opentofu-backend    | State file and DynamoDB encryption | Disabled |
| openbao-auto-unseal | OpenBao seal/unseal operations     | Enabled  |

## Compute

### Public Gateway

Lightsail instance in us-east-1b running Amazon Linux 2023 on nano bundle, serving as a public entry point to expose internal home network applications. Acts as a DMZ, bridging the public internet with the private Tailscale network via Caddy reverse proxy.

- Static IP address
- SSH (port 22) and HTTPS (port 443) exposed
- Dedicated key pair for access

## Storage

### Offsite Backup

S3 bucket for offsite backups of home storage layer and virtual machines with:

- Server-side encryption (AES256)
- Immediate transition to Glacier Flexible Retrieval
- Dedicated IAM user with minimal required permissions
- Public access blocked

## Email

### SES (Simple Email Service)

Domain identity for `shdr.ch` providing outbound email capability for the home network. Postfix on the messaging stack acts as an SMTP relay, allowing any internal service to send emails through SES.

- Domain identity with DKIM authentication
- Dedicated SMTP user with send-only permissions
- DNS records managed in Cloudflare (DKIM CNAMEs, verification TXT)
