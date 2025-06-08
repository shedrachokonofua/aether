# AWS

## Budget

Monthly budget of $15 USD with notifications at 50%, 80%, and 100% of actual costs, plus 100% of forecasted costs.

## Security

Access Analyzer monitors for unused IAM roles and users, with a 90-day unused access threshold.

## Storage

### Offsite Backup

S3 bucket for offsite backups of home storage layer and virtual machines with:

- Server-side encryption (AES256)
- Immediate transition to Glacier Flexible Retrieval
- Dedicated IAM user with minimal required permissions
- Public access blocked
