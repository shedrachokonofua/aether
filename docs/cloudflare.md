# Cloudflare

## Domain

The root domain `shdr.ch` (derived from "Shedrach" without vowels) is managed through Cloudflare with full DNS management.

## Zone Configuration

The zone is configured with the following settings:

- **SSL Mode**: Strict - Requires valid SSL certificates on origin servers
- **Zone Type**: Full - Complete DNS management through Cloudflare

## DNS Management

### Public Gateway

The domain routes public traffic through the AWS-hosted public gateway with Cloudflare's CDN and DDoS protection enabled.

| Record Type | Name | Target                | Proxied | Purpose                    |
| ----------- | ---- | --------------------- | ------- | -------------------------- |
| A           | @    | AWS Public Gateway IP | Yes     | Root domain routing        |
| A           | \*   | AWS Public Gateway IP | Yes     | Wildcard subdomain routing |

### Email (ProtonMail)

The domain is configured for ProtonMail email service, providing end-to-end encrypted email with custom domain support. This includes all necessary DNS records for email authentication (SPF, DKIM, DMARC) and proper mail routing.

| Record Type | Name                    | Priority | Purpose               |
| ----------- | ----------------------- | -------- | --------------------- |
| MX          | shdr.ch                 | 10       | Primary mail server   |
| MX          | shdr.ch                 | 20       | Secondary mail server |
| CNAME       | protonmail.\_domainkey  | -        | DKIM verification 1   |
| CNAME       | protonmail2.\_domainkey | -        | DKIM verification 2   |
| CNAME       | protonmail3.\_domainkey | -        | DKIM verification 3   |
| TXT         | \_dmarc                 | -        | DMARC policy          |
| TXT         | shdr.ch                 | -        | SPF record            |
| TXT         | shdr.ch                 | -        | Domain verification   |

### Email (AWS SES)

DNS records for AWS SES domain verification and DKIM authentication, enabling outbound email from the home network.

| Record Type | Name                  | Purpose                 |
| ----------- | --------------------- | ----------------------- |
| CNAME       | \<token\>.\_domainkey | DKIM verification 1     |
| CNAME       | \<token\>.\_domainkey | DKIM verification 2     |
| CNAME       | \<token\>.\_domainkey | DKIM verification 3     |
| TXT         | \_amazonses           | SES domain verification |

The SPF record includes `amazonses.com` to authorize SES as a sender.

### ACME DNS Validation

Caddy uses Cloudflare's DNS API to perform ACME DNS validation for `*.home.shdr.ch` subdomains. This allows automatic SSL certificate provisioning without requiring explicit DNS records in Cloudflare for each internal service.
