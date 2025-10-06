# AWS

## Budget

Monthly budget of $15 USD with notifications at 50%, 80%, and 100% of actual costs, plus 100% of forecasted costs.

## Security

Access Analyzers monitor for:

- Unused IAM roles and users with a 90-day unused access threshold
- External access to account resources

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
