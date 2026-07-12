# Tailscale

## Network Configuration

Tailscale provides secure mesh networking for **roaming human access** to home infrastructure (subnet routes via the admin gateway) with policy-based ACLs. Fixed cloud infrastructure (AWS/GCP) now reaches home over the **routed WireGuard fabric** (`10.1/10.2`), not Tailscale — the cloud Tailscale clients were retired.

### Groups and Tags

The tailnet is organized using groups and tags for role-based access control:

| Type       | Name                                | Members/Owners                | Purpose                         |
| ---------- | ----------------------------------- | ----------------------------- | ------------------------------- |
| Group      | group:admin                         | Primary user                  | Explicit admin identity         |
| Autogroup  | autogroup:owner, autogroup:admin    | Tailscale owner/admin roles   | Admin and backup-admin devices  |
| Tag        | tag:home-gateway                    | Admin sources                 | Shared home gateway node        |
| Tag        | tag:admin-gateway                   | Admin sources                 | Admin-only home gateway node    |

### Access Control Rules

ACLs enforce network segmentation and least-privilege access:

| Source                                       | Destination                         | Purpose                                  |
| -------------------------------------------- | ----------------------------------- | ---------------------------------------- |
| group:admin, autogroup:owner, autogroup:admin | tag:home-gateway:\*                 | Admin access to the shared gateway       |
| group:admin, autogroup:owner, autogroup:admin | tag:admin-gateway:\*                | Admin access to the admin gateway        |
| group:admin, autogroup:owner, autogroup:admin | autogroup:self:\*                   | Admin users can reach their own devices  |
| group:admin, autogroup:owner, autogroup:admin | 10.0.0.0/8:\*, 192.168.0.0/16:\*   | Admin access through subnet routes       |
| autogroup:shared                             | tag:home-gateway:443,53,2222        | Shared-device recipients                 |
| tag:home-gateway, tag:admin-gateway          | 10.0.0.0/8:\*, 192.168.0.0/16:\*   | Gateway access to internal networks      |

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

- **Admin Gateway OAuth Client** - Generates auth keys with `tag:admin-gateway` for the admin-only gateway container

## SSO / OIDC (Keycloak)

Human login to the tailnet is via Keycloak OIDC (owner `s@shdr.ch`), not Google/GitHub. Not Terraformable — manual setup:

- **WebFinger:** the `shdr.ch` Caddy serves `/.well-known/webfinger` returning issuer `https://auth.shdr.ch/realms/aether` for `acct:s@shdr.ch`.
- **Keycloak client** `tailscale-sso` — confidential; scopes `openid`/`profile`/`email`; redirect `https://login.tailscale.com/a/oauth_response`; PKCE disabled (Tailscale doesn't support it).
- **Email override:** the Keycloak user email differs from the WebFinger identity, so a `tailscale_email=s@shdr.ch` user attribute + protocol mapper overrides the `email` claim (see `tofu/home/keycloak.tf`).
- **Users:** backup admin `shedrachokonofua@gmail.com` invited via Google; friends invite via their own IdP into `group:friends` with scoped ACLs.

## Disaster Recovery

The tailnet is a cloud resource and survives infra loss. Rebuild sequence:

1. Log into the Tailscale admin console (Keycloak SSO from phone/laptop).
2. Generate a **one-time auth key** for gateway bootstrap (break-glass; not stored anywhere).
3. Rebuild infra; use the one-time key for initial gateway auth.
4. Steady-state gateway auth keys come from the Tofu-provisioned OAuth clients (home/admin gateway).
