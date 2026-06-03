# Tailscale

## Network Configuration

Tailscale provides secure mesh networking between home infrastructure and cloud resources, with policy-based access control and automatic subnet routing.

### Groups and Tags

The tailnet is organized using groups and tags for role-based access control:

| Type       | Name                                | Members/Owners                | Purpose                         |
| ---------- | ----------------------------------- | ----------------------------- | ------------------------------- |
| Group      | group:admin                         | Primary user                  | Explicit admin identity         |
| Autogroup  | autogroup:owner, autogroup:admin    | Tailscale owner/admin roles   | Admin and backup-admin devices  |
| Tag        | tag:home-gateway                    | Admin sources                 | Shared home gateway node        |
| Tag        | tag:admin-gateway                   | Admin sources                 | Admin-only home gateway node    |
| Tag        | tag:public-gateway                  | Admin sources                 | AWS public gateway machine      |

### Access Control Rules

ACLs enforce network segmentation and least-privilege access:

| Source                                       | Destination                         | Purpose                                  |
| -------------------------------------------- | ----------------------------------- | ---------------------------------------- |
| group:admin, autogroup:owner, autogroup:admin | tag:home-gateway:\*                 | Admin access to the shared gateway       |
| group:admin, autogroup:owner, autogroup:admin | tag:admin-gateway:\*                | Admin access to the admin gateway        |
| group:admin, autogroup:owner, autogroup:admin | tag:public-gateway:\*               | Admin access to the public gateway       |
| group:admin, autogroup:owner, autogroup:admin | autogroup:self:\*                   | Admin users can reach their own devices  |
| group:admin, autogroup:owner, autogroup:admin | 10.0.0.0/8:\*, 192.168.0.0/16:\*   | Admin access through subnet routes       |
| autogroup:shared                             | tag:home-gateway:443,53,2222        | Shared-device recipients                 |
| tag:home-gateway, tag:admin-gateway          | 10.0.0.0/8:\*, 192.168.0.0/16:\*   | Gateway access to internal networks      |
| tag:public-gateway                           | 10.0.2.2:9443                       | Access to home gateway Caddy public port |

### DNS

The home gateway stack runs two Tailscale nodes and two authoritative-only dnsmasq listeners:

| Node | Tag | Tailscale IP | Audience | Subnet routes |
| --- | --- | --- | --- | --- |
| `aether-home-gateway` | `tag:home-gateway` | `100.76.131.97` | Shared with cofounders | None |
| `aether-admin-gateway` | `tag:admin-gateway` | `100.99.79.59` | Admin tailnet only | `10.0.0.0/8`, `192.168.0.0/16` |

Admin tailnet split DNS points to the LAN router (`10.0.0.1`) through the admin-only subnet routes. The router/LAN DNS path returns the normal internal records, including the home gateway LAN IP (`10.0.2.2`) for `home.shdr.ch`.

| Domain         | Nameserver | Purpose                                      |
| -------------- | ---------- | -------------------------------------------- |
| home.shdr.ch | `10.0.0.1` | Admin `*.home.shdr.ch` -> LAN DNS records |
| k8s.seven30.xyz | `10.0.0.1` | Admin vcluster API -> LAN DNS records |
| mars.seven30.xyz | `10.0.0.1` | Admin Mars routes -> LAN DNS records |

Cofounder tailnets use their own split DNS entries pointed at the shared gateway (`100.76.131.97`). The shared dnsmasq listener returns only the shared gateway Tailscale IP, never internal LAN IPs. Caddy binding and the shared catch-all decide what is exposed on `100.76.131.97:443`; internal-only routes do not leak through DNS.

### Subnet Routing

Subnet routing with automatic approval is configured for the admin gateway only:

| Subnet         | Auto-approver    | Description          |
| -------------- | ---------------- | -------------------- |
| 10.0.0.0/8     | tag:admin-gateway | VyOS network         |
| 192.168.0.0/16 | tag:admin-gateway | Bell Gigahub network |

### OAuth Clients

OAuth clients are provisioned for automated Tailscale authentication:

- **Public Gateway OAuth Client** - Generates auth keys with `tag:public-gateway` for automated public gateway provisioning
- **Admin Gateway OAuth Client** - Generates auth keys with `tag:admin-gateway` for the admin-only gateway container
