# Tailscale

## Network Configuration

Tailscale provides secure mesh networking between home infrastructure and cloud resources, with policy-based access control and automatic subnet routing.

### Groups and Tags

The tailnet is organized using groups and tags for role-based access control:

| Type  | Name               | Members/Owners | Purpose                      |
| ----- | ------------------ | -------------- | ---------------------------- |
| Group | group:admin        | Primary user   | Administrative access        |
| Tag   | tag:home-gateway   | group:admin    | Home network gateway machine |
| Tag   | tag:public-gateway | group:admin    | AWS public gateway machine   |

### Access Control Rules

ACLs enforce network segmentation and least-privilege access:

| Source             | Destination       | Purpose                                  |
| ------------------ | ----------------- | ---------------------------------------- |
| group:admin        | \*:\*             | Full administrative access               |
| tag:home-gateway   | 10.0.0.0/8:\*     | Access to home VyOS network              |
| tag:home-gateway   | 192.168.0.0/16:\* | Access to home Bell Gigahub network      |
| tag:public-gateway | 10.0.2.2:9443     | Access to home gateway Caddy public port |

### DNS

The Tailscale network uses the home network router as its nameserver:

- Primary nameserver: `10.0.0.1` (VyOS router on home network)

### Subnet Routing

Subnet routing with automatic approval is configured for the home gateway to advertise private networks to the tailnet:

| Subnet         | Auto-approver    | Description          |
| -------------- | ---------------- | -------------------- |
| 10.0.0.0/8     | tag:home-gateway | VyOS network         |
| 192.168.0.0/16 | tag:home-gateway | Bell Gigahub network |

### OAuth Clients

OAuth clients are provisioned for automated Tailscale authentication:

- **Public Gateway OAuth Client** - Generates auth keys with `tag:public-gateway` for automated public gateway provisioning
