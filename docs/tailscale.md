# Tailscale

## Network Configuration

Tailscale provides secure mesh networking between home infrastructure and cloud resources, with policy-based access control and automatic subnet routing.

### Groups and Tags

The tailnet is organized using groups and tags for role-based access control:

| Type       | Name                                | Members/Owners                | Purpose                         |
| ---------- | ----------------------------------- | ----------------------------- | ------------------------------- |
| Group      | group:admin                         | Primary user                  | Explicit admin identity         |
| Autogroup  | autogroup:owner, autogroup:admin    | Tailscale owner/admin roles   | Admin and backup-admin devices  |
| Tag        | tag:home-gateway                    | Admin sources                 | Home network gateway machine    |
| Tag        | tag:public-gateway                  | Admin sources                 | AWS public gateway machine      |

### Access Control Rules

ACLs enforce network segmentation and least-privilege access:

| Source                                       | Destination                         | Purpose                                  |
| -------------------------------------------- | ----------------------------------- | ---------------------------------------- |
| group:admin, autogroup:owner, autogroup:admin | tag:home-gateway:\*                 | Admin access to the home gateway         |
| group:admin, autogroup:owner, autogroup:admin | tag:public-gateway:\*               | Admin access to the public gateway       |
| group:admin, autogroup:owner, autogroup:admin | autogroup:self:\*                   | Admin users can reach their own devices  |
| group:admin, autogroup:owner, autogroup:admin | 10.0.0.0/8:\*, 192.168.0.0/16:\*   | Admin access through subnet routes       |
| autogroup:shared                             | tag:home-gateway:443,53,2222        | Shared-device recipients                 |
| tag:home-gateway                             | 10.0.0.0/8:\*, 192.168.0.0/16:\*   | Home gateway access to internal networks |
| tag:public-gateway                           | 10.0.2.2:9443                       | Access to home gateway Caddy public port |

### DNS

Admin tailnet devices and shared peer tailnets query the home gateway Tailscale DNS listener for split DNS. That listener returns the Tailscale IP only for routes Caddy exposes on the Tailscale interface, and returns the home gateway LAN IP for the rest of `home.shdr.ch`.

| Domain         | Nameserver | Purpose                                      |
| -------------- | ---------- | -------------------------------------------- |
| home.shdr.ch   | Home gateway Tailscale IP | Mixed answers: shared routes -> Tailscale listener, admin-only routes -> LAN listener |
| k8s.seven30.xyz | Home gateway Tailscale IP | Seven30 vcluster API via Caddy |
| mars.seven30.xyz | Home gateway Tailscale IP | Mars vcluster routes via Caddy |

The dnsmasq listener on the home gateway's Tailscale IP is authoritative for these split zones. Cofounders configure their own tailnet split DNS to that listener, so allowed shared routes resolve to the Tailscale interface while admin-only routes resolve to `10.0.2.2`, which shared-device recipients cannot reach. Admin devices use the same DNS listener and reach admin-only services through the approved subnet routes.

### Subnet Routing

Subnet routing with automatic approval is configured for the home gateway to advertise private networks to the tailnet:

| Subnet         | Auto-approver    | Description          |
| -------------- | ---------------- | -------------------- |
| 10.0.0.0/8     | tag:home-gateway | VyOS network         |
| 192.168.0.0/16 | tag:home-gateway | Bell Gigahub network |

### OAuth Clients

OAuth clients are provisioned for automated Tailscale authentication:

- **Public Gateway OAuth Client** - Generates auth keys with `tag:public-gateway` for automated public gateway provisioning
