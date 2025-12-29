# Tailscale Integration — Full E2E Plan

## Goals
1. **Integrate Tailscale SSO with Keycloak** — humans login via your IdP
2. **Eliminate long-lived OAuth credentials** — gateway provisioning via WIF
3. **Bidirectional routing** — home machines reach Tailnet nodes
4. **MagicDNS** — resolve Tailnet hostnames from home network

---

## Phase 1: Custom OIDC SSO (Human Login)

**Outcome:** Tailscale users authenticate via Keycloak instead of Google/GitHub.

**Status:** Complete — SSO working via `s@shdr.ch`

### Approach
Create **new tailnet** with Keycloak OIDC from the start → no migration needed.

### Changes

#### WebFinger Endpoint — Home Gateway Caddy
Add to [Caddyfile.j2](file:///home/shdrch/projects/aether/ansible/playbooks/home_gateway_stack/caddy/Caddyfile.j2) (serves `shdr.ch` on port 9443):

```caddy
shdr.ch {
  handle /.well-known/webfinger {
    header Content-Type "application/jrd+json"
    respond `{"subject":"acct:s@shdr.ch","links":[{"rel":"http://openid.net/specs/connect/1.0/issuer","href":"https://auth.shdr.ch/realms/aether"}]}`
  }
  # ... existing shdr.ch handling
}
```

#### Keycloak Client
- [ ] Create client `tailscale-sso` in aether realm
- [ ] Client type: Confidential
- [ ] Scopes: `openid`, `profile`, `email`
- [ ] Redirect URI: `https://login.tailscale.com/a/oauth_response`
- [ ] Disable PKCE — [Tailscale docs](https://tailscale.com/kb/1240/sso-custom-oidc#notes): "Tailscale doesn't support PKCE"

> [!IMPORTANT]
> **Email Override Required:** Keycloak user email (`shedrachokonofua@gmail.com`) differs from WebFinger identity (`s@shdr.ch`). Solved via:
> 1. Added `tailscale_email` to realm User Profile (`keycloak_realm_user_profile` in Terraform)
> 2. Set `tailscale_email: s@shdr.ch` attribute on user
> 3. Created `keycloak_openid_user_attribute_protocol_mapper` to override `email` claim
> 
> See [keycloak.tf](file:///home/shdrch/projects/aether/tofu/home/keycloak.tf) for implementation.

#### Tailscale Setup
- [x] Go to [Sign up with OIDC](https://login.tailscale.com/start/oidc)
- [x] Enter admin email: `s@shdr.ch`
- [x] Complete OIDC setup with Keycloak client ID/secret

#### User Access Model
| User | Email | Auth Method | Role |
|------|-------|-------------|------|
| Primary owner | `s@shdr.ch` | Keycloak OIDC | Owner |
| Backup admin | `shedrachokonofua@gmail.com` | Invitation (Google) | Admin |
| Friends | Their email | Invitation (their IdP) | Limited ACL |

- [x] After tailnet created, invite `shedrachokonofua@gmail.com` as admin (optional backup)

#### Friend ACLs (Future Scope)
> [!NOTE]
> Friend access is out of scope for this implementation but the infrastructure supports it. When ready:
> 1. Invite friend via Tailscale admin
> 2. Add to `group:friends` in ACL
> 3. They auth via their own IdP

Example ACL structure for future reference:
```hcl
groups : {
  "group:admin"   : [local.tailscale.user],
  "group:friends" : ["friend@gmail.com"],
},
acls : [
  // Friends: game streaming + AI chat only
  {
    action : "accept",
    src : ["group:friends"],
    dst : [
      "10.0.3.13:47989-48010",  // game-server sunshine
      "10.0.3.3:8080",          // openwebui
    ],
  },
],
```

---

## Phase 2: Gateway Credential Security (Machine Auth)

**Outcome:** Gateways authenticate via cert → Keycloak → Tailscale WIF. **Zero static secrets.**

### Flow
```
Gateway (step-ca cert) → mTLS → Caddy → Keycloak (X.509 auth) → OIDC token → Tailscale WIF
```

### Changes

#### Step-CA Client Role
- [ ] Create `ansible/roles/vm_step_ca_client` role:
  - Request cert via `machine-bootstrap` provisioner
  - Install `step ca renew --daemon` systemd service
  - Store cert/key in `/etc/step/certs/`

#### Caddy mTLS (auth.shdr.ch)
Update [home_gateway_stack/caddy/Caddyfile.j2](file:///home/shdrch/projects/aether/ansible/playbooks/home_gateway_stack/caddy/Caddyfile.j2):
```caddy
auth.shdr.ch {
  tls {
    client_auth {
      mode request  # Optional - humans won't present cert
      trust_pool file /etc/step/certs/root_ca.crt  # Verify cert signed by step-ca
    }
  }
  
  reverse_proxy {{ vm.keycloak.ip }}:{{ vm.keycloak.ports.http }} {
    header_up X-SSL-Client-Cert {http.request.tls.client.certificate_pem}
  }
}
```

> [!NOTE]
> `trust_pool` is required so Caddy validates certs are signed by step-ca before forwarding. Without it, forged certs could be accepted.

- [ ] Deploy step-ca root cert to home gateway (`/etc/step/certs/root_ca.crt`)
- [ ] Update Caddyfile with mTLS config

**Source:** [Caddy client_auth docs](https://caddyserver.com/docs/caddyfile/directives/tls#client_auth)

#### Keycloak X.509 SPI
Update [keycloak.conf.j2](file:///home/shdrch/projects/aether/ansible/playbooks/keycloak/templates/keycloak.conf.j2):
```properties
# Read client cert from reverse proxy header
spi-x509cert-lookup-provider=haproxy
spi-x509cert-lookup-haproxy-ssl-client-cert=X-SSL-Client-Cert
spi-x509cert-lookup-haproxy-ssl-cert-chain-prefix=  # Empty = single header, no chain
spi-x509cert-lookup-haproxy-certificate-chain-length=1
```

- [ ] Add X.509 SPI config to keycloak.conf
- [ ] Redeploy Keycloak

**Source:** [Keycloak reverse proxy X.509 docs](https://www.keycloak.org/server/reverseproxy#_extracting_client_certificates_from_http_headers)

#### Keycloak Client (Terraform)
```hcl
resource "keycloak_openid_client" "tailscale_gateway" {
  realm_id  = keycloak_realm.aether.id
  client_id = "tailscale-gateway"
  name      = "Tailscale Gateway"
  enabled   = true

  access_type               = "CONFIDENTIAL"
  client_authenticator_type = "client-x509"
  service_accounts_enabled  = true
  standard_flow_enabled     = false

  extra_config = {
    "attributes.x509.subjectdn" = "CN=aether-.*-gateway.*"
  }
}
```

- [ ] Add client to [keycloak.tf](file:///home/shdrch/projects/aether/tofu/home/keycloak.tf)

#### Tailscale Workload Identity (Manual)
- [ ] Create federated identity in [Trust Credentials](https://login.tailscale.com/admin/settings/trust-credentials):
  - Issuer: `https://auth.shdr.ch/realms/aether`
  - Subject: service account subject from token
  - Scopes: `auth_keys`
  - Tags: `tag:home-gateway`, `tag:public-gateway`

#### Gateway Wrapper Script
```bash
#!/bin/bash
# Get OIDC token from Keycloak using client cert
TOKEN=$(curl -s --cert /etc/step/certs/cert.pem --key /etc/step/certs/key.pem \
  -X POST "https://auth.shdr.ch/realms/aether/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=tailscale-gateway" | jq -r .access_token)

# Join tailnet
tailscale up --client-id=tailscale-gateway --id-token="$TOKEN" --advertise-tags=tag:home-gateway
```

- [ ] Create wrapper script
- [ ] Deploy via Ansible to gateways

#### Cleanup
- [ ] Remove `tailscale_oauth_client_secret` from [secrets.yml](file:///home/shdrch/projects/aether/secrets/secrets.yml)
- [ ] Remove `tailscale_oauth_client` from [tailscale.tf](file:///home/shdrch/projects/aether/tofu/tailscale.tf)

---

## Phase 3: VyOS Route (Home → Tailnet)

- [ ] Add static route:
  ```
  set protocols static route 100.64.0.0/10 next-hop 10.0.2.2
  ```

---

## Phase 4: MagicDNS (AdGuard)

- [ ] Add AdGuard upstream:
  ```
  [/*.ts.net/]100.100.100.100
  ```

---

## Documentation Updates

#### [trust-model.md](file:///home/shdrch/projects/aether/docs/trust-model.md)
- Add Tailscale to "External Trust Relationships" section
- Document Keycloak as OIDC bridge for machine auth
- Update identity planes table

#### [tailscale.md](file:///home/shdrch/projects/aether/docs/tailscale.md)
Add manual setup runbook (not Terraformable):
- OIDC SSO configuration (Keycloak client ID/secret)
- WebFinger endpoint location
- Trust Credentials / WIF setup (issuer, subject patterns, scopes, tags)
- User management (inviting admins, friend ACL patterns)

---

## Bootstrap / Disaster Recovery

> [!IMPORTANT]
> Tailnet is a cloud resource — it survives infrastructure loss.

**Disaster recovery sequence:**
1. Login to Tailscale admin console (via Keycloak on phone/laptop)
2. Generate **one-time auth key** for gateway bootstrap
3. Rebuild infra, use one-time key for initial gateway auth
4. Once Keycloak is back up, WIF handles all future re-auths

The one-time key is a **break-glass** mechanism, not stored anywhere.

---

## Verification

| Test | Method |
|------|--------|
| Human SSO | Login to Tailscale via `s@shdr.ch` |
| Gateway WIF | `tailscale status` shows gateway joined |
| Friend access | Friend can reach game-server, blocked from other services |
| Home → Tailnet | `ping 100.x.x.x` from home machine |
| MagicDNS | `dig node.tailnet.ts.net` from home |
