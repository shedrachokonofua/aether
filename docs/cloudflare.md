# Cloudflare

## Domain

The root domain `shdr.ch` (derived from "Shedrach" without vowels) is managed through Cloudflare.

## DNS Management

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

### ACME DNS Validation

Caddy uses Cloudflare's DNS API to perform ACME DNS validation for `*.home.shdr.ch` subdomains. This allows automatic SSL certificate provisioning without requiring explicit DNS records in Cloudflare for each internal service.
