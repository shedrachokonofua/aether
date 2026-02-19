# Software Studio — Seven30

3-person software studio. Workloads run on the existing Talos Kubernetes cluster under `seven30.xyz`. Clean separation from the homelab — `shdr.ch` is personal infrastructure, `seven30.xyz` is Seven30.

## Goal

Give co-founders full development capabilities (kubectl, GitLab, deploy apps) without exposing the homelab. Network-level isolation by default, auth as a second layer.

## Architecture

Co-founders access studio services via **Tailscale node sharing** — the home gateway device is shared with them, but they never join the admin tailnet. Their devices stay on their own tailnets, structurally isolated.

```
┌──────────────────────────────┐   ┌─────────────────────────────────┐
│       ADMIN TAILNET          │   │    CO-FOUNDER'S OWN TAILNET     │
│                              │   │                                 │
│  You (admin)                 │   │  Co-founder device              │
│  ├── tag:home-gateway:*      │   │  └── shared: aether-home-gw    │
│  ├── tag:public-gateway:*    │   │      └── port 443 only (ACL)   │
│  └── autogroup:self:*        │   │                                 │
│                              │   │  MagicDNS custom record:        │
│  Shared device:              │   │  *.home.shdr.ch → 100.76.131.97│
│  aether-home-gateway ────────┼───┤                                 │
│  (tag:home-gateway)          │   │  No access to 10.0.0.0/8       │
│                              │   │  No subnet routes exposed       │
└──────────────────────────────┘   └─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    HOME GATEWAY (Caddy)                              │
│                                                                     │
│  LAN (10.0.2.2:443)           Tailscale (100.76.131.97:443)        │
│  ├── gitlab.home.shdr.ch      ├── gitlab.home.shdr.ch              │
│  ├── registry.gitlab...       ├── registry.gitlab...               │
│  ├── pages.gitlab...          ├── pages.gitlab...                  │
│  ├── grafana.home.shdr.ch     │   (studio routes only)             │
│  ├── *.apps.home.shdr.ch     │                                     │
│  └── ... (everything)        │   :9443 (public, LAN-bound)        │
│                              │   ├── *.shdr.ch                     │
│  default_bind 10.0.2.2      │   ├── seven30.xyz                   │
│                              │   └── *.seven30.xyz                 │
└──────────────┬───────────────┴──────────────────────┬──────────────┘
               │                                      │
               ▼                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    HOST CLUSTER (Talos, 3 nodes)                     │
│                                                                     │
│  Gateway API (10.0.3.19)                                           │
│  ├── Listener: *.apps.home.shdr.ch  (personal k8s apps)            │
│  └── Listener: *.seven30.xyz        (Seven30 k8s apps)             │
│                                                                     │
│  Platform:                  Personal:      Seven30 vcluster:       │
│  ├── Cilium                 ├── OpenWebUI   ├── Projects            │
│  ├── Knative                ├── Hubble UI   ├── Own namespaces      │
│  ├── Crossplane             └── Headlamp    ├── Own CRDs/Helm      │
│  └── vcluster operator                      └── All 3 = admin      │
└─────────────────────────────────────────────────────────────────────┘
```

## What Already Exists

| Component | Status | Details |
| --- | --- | --- |
| Cloudflare zone | Done | `seven30.xyz`, own account (`cloudflare.seven30` provider) |
| DNS wildcard | Done | `*.seven30.xyz` → public gateway IP (proxied) |
| Public Caddy | Done | `seven30.xyz, *.seven30.xyz` → home gateway `:9443` |
| Home Caddy `:9443` | Done | `seven30.xyz` → static landing page (`/srv/seven30`) |
| Tailscale SSO | Done | Phase 1 of `full-tailscale-integration.md` |
| Tailscale ACL | Done | Terraform-managed, deny-by-default |

## Access Model

Three layers, each tighter:

| Layer | Controls | Mechanism |
| --- | --- | --- |
| Network | Can they reach the IP at all | Tailscale node sharing — shared device only, `autogroup:shared` ACL → port 443 only |
| Reverse proxy | Which services exist on that IP | Caddy `bind` — only studio routes listen on the Tailscale interface |
| Application | Who can use each service | Keycloak OIDC — GitLab and k8s apps authenticate via Keycloak |

### What Seven30 members can reach

| Service | Hostname | Via |
| --- | --- | --- |
| GitLab | `gitlab.home.shdr.ch` | Caddy (Tailscale bind) → GitLab VM |
| GitLab Registry | `registry.gitlab.home.shdr.ch` | Caddy (Tailscale bind) → GitLab VM |
| GitLab Pages | `pages.gitlab.home.shdr.ch` | Caddy (Tailscale bind) → GitLab VM |
| Seven30 apps (public) | `*.seven30.xyz` | Cloudflare → Public Caddy → Home Caddy `:9443` → K8s VIP |

### What Seven30 members cannot reach

Everything else. Not "blocked by auth" — the services don't exist on the Tailscale interface. `grafana.home.shdr.ch`, `proxmox`, etc. only bind to the LAN IP (`10.0.2.2`). Connection refused, not 403. No subnet routes are exposed through node sharing, so `10.0.0.0/8` is structurally unreachable.

---

## Tailscale — Node Sharing

### Why Node Sharing (not tailnet membership)

Co-founders never join the admin tailnet. Instead, the `aether-home-gateway` device is **shared** with them. Each co-founder receives a share link and the shared device appears in *their own* tailnet as a remote machine.

| Approach | Co-founders on your tailnet | Subnet routes exposed | ACL misconfiguration risk | Your devices visible |
| --- | --- | --- | --- | --- |
| Group membership | Yes | Yes (need ACL to block) | High | Yes |
| **Node sharing** | **No** | **No (structurally blocked)** | **Low** | **No** |

Node sharing is safer for both sides:
- **For you**: co-founder devices never appear on your tailnet. No ACL rule can accidentally grant them broader access. Your admin scope (`group:admin`) is limited to infrastructure tags + your own devices — not "everything."
- **For co-founders**: your devices never appear on their tailnet. The shared machine is quarantined by default (cannot initiate connections back to them).

### ACL (tailscale.tf)

```hcl
data "tailscale_device" "home_gateway" {
  hostname = "aether-home-gateway"
  wait_for = "30s"
}

resource "tailscale_acl" "tailnet_acl" {
  acl = jsonencode({
    groups : {
      "group:admin" : [local.tailscale.user],
    },
    tagOwners : {
      "tag:home-gateway"   : ["group:admin"],
      "tag:public-gateway" : ["group:admin"],
    },
    acls : [
      // Admin: scoped to infrastructure + own devices only
      {
        action : "accept",
        src : ["group:admin"],
        dst : [
          "tag:home-gateway:*",
          "tag:public-gateway:*",
          "autogroup:self:*",
        ],
      },
      // Shared users (co-founders via node sharing): HTTPS, DNS, GitLab SSH
      {
        action : "accept",
        src : ["autogroup:shared"],
        dst : ["tag:home-gateway:443,53,2222"],
      },
      // Home gateway: internal networks
      {
        action : "accept",
        src : ["tag:home-gateway"],
        dst : [
          "10.0.0.0/8:*",
          "192.168.0.0/16:*",
        ],
      },
      // Public gateway: home gateway Caddy public port only
      {
        action : "accept",
        src : ["tag:public-gateway"],
        dst : ["10.0.2.2:9443"],
      },
    ],
    autoApprovers : {
      routes : {
        "10.0.0.0/8"     : ["tag:home-gateway"],
        "192.168.0.0/16" : ["tag:home-gateway"],
      },
    },
  })
}
```

Key differences from the old plan:
- No `group:seven30`. Co-founders aren't tailnet members.
- `group:admin` scoped down from `*:*` to tagged infrastructure + `autogroup:self`.
- `autogroup:shared` automatically matches anyone with whom a device is shared. No email management needed.

### DNS — Tailscale Split DNS + dnsmasq

Tailscale doesn't support custom DNS A records (still an open feature request). Instead, co-founders use **Tailscale split DNS** — their tailnet forwards DNS queries for specific domains to a lightweight dnsmasq server running on the home gateway's Tailscale interface.

**dnsmasq on the home gateway** (`ansible/playbooks/home_gateway_stack/dnsmasq/`):

- Authoritative-only — responds to configured domains, returns NXDOMAIN for everything else
- No upstream forwarding, no recursion, no cache poisoning vector
- Binds to the Tailscale IP only (`100.76.131.97:53`)
- Runs as a rootful Podman container with host networking, started after the Tailscale container

Records served:

| Query | Answer | Purpose |
| --- | --- | --- |
| `*.home.shdr.ch` | `100.76.131.97` | GitLab, registry, pages via Caddy |
| `k8s.seven30.xyz` | `100.76.131.97` | vcluster API via Caddy |

**Co-founder one-time setup** — add split DNS entries in their own Tailscale admin console (DNS → Nameservers → Add Split DNS):

| Domain | Nameserver | Notes |
| --- | --- | --- |
| `home.shdr.ch` | `100.76.131.97` | Resolves `*.home.shdr.ch` via dnsmasq |
| `k8s.seven30.xyz` | `100.76.131.97` | Resolves vcluster API via dnsmasq |

The ACL allows `autogroup:shared` to reach `tag:home-gateway:443,53,2222` — HTTPS for Caddy, DNS for split DNS, and GitLab SSH (socat forward to GitLab VM).

Public domains (`*.seven30.xyz`) resolve normally via Cloudflare DNS.

### Sharing the Device

Done via the Tailscale admin console (not Terraform — no resource for this yet):

1. Go to **Machines** → `aether-home-gateway` → **Share**
2. Enter co-founder's email
3. They receive a link, device appears in their tailnet

The device retains its `tag:home-gateway` tag on the admin side. On the recipient side, tags are stripped — they just see an IP (`100.76.131.97`).

### Security Analysis

**Q: Can co-founders reach `10.0.0.0/8` (internal LAN)?**

No. Node sharing does not expose subnet routes. The shared device has `TS_ROUTES: "10.0.0.0/8,192.168.0.0/16"` but these routes are only advertised within the admin tailnet. Shared recipients see only the device's Tailscale IP. This is structural, not policy — there's no ACL to misconfigure.

**Q: Can co-founders reach port 9443?**

No. `autogroup:shared` ACL only allows ports 443 (Caddy HTTPS), 53 (split DNS), and 2222 (GitLab SSH). Port 9443 (public ingress) is only reachable by `tag:public-gateway`.

**Q: What's exposed on port 53?**

A dnsmasq instance that answers only `*.home.shdr.ch` and `k8s.seven30.xyz` with the home gateway's own Tailscale IP. No recursion, no forwarding, no upstream DNS. Worst case: an attacker learns the Tailscale IP they already have.

**Q: Can co-founders see my other devices?**

No. They're on separate tailnets. The shared device is the only thing visible to them. Your personal devices, other infrastructure — none of it exists in their tailnet.

**Q: Can I see co-founders' devices?**

No. Node sharing is one-way. You share a device with them; their devices don't appear on your tailnet.

**Q: What if a co-founder's device is compromised?**

Attacker gets access to `100.76.131.97:443`, `:53`, and `:2222`. They can reach Caddy (studio routes only), dnsmasq (static records, no recursion), and GitLab SSH (key-authenticated). Next layer is Keycloak OIDC for web, SSH keys for git. Blast radius: GitLab. No access to homelab infra, no lateral movement, no subnet routes.

**Q: What if I want to revoke access?**

Unshare the device from the Tailscale admin console. Immediate effect.

---

## Caddy Configuration

### Home Gateway Caddyfile Changes

**Global options** — lock all routes to LAN by default:
```caddy
{
  default_bind 10.0.2.2
}
```

All existing routes (grafana, proxmox, media, etc.) continue to work on LAN unchanged. They're structurally invisible on the Tailscale interface — connection refused, not 403.

**Studio routes** — bind to both LAN and Tailscale:
```caddy
# Studio services: accessible from both LAN and Tailscale
gitlab.home.shdr.ch {
  bind 10.0.2.2 {{ tf_outputs.home_gateway_tailscale_ip.value }}
  reverse_proxy {{ vm.gitlab.ip }}
}

registry.gitlab.home.shdr.ch {
  bind 10.0.2.2 {{ tf_outputs.home_gateway_tailscale_ip.value }}
  reverse_proxy {{ vm.gitlab.ip }}:{{ vm.gitlab.ports.gitlab_registry }}
}

pages.gitlab.home.shdr.ch {
  bind 10.0.2.2 {{ tf_outputs.home_gateway_tailscale_ip.value }}
  reverse_proxy {{ vm.gitlab.ip }}:{{ vm.gitlab.ports.gitlab_pages }}
}
```

The Tailscale IP comes from `tofu output` → `tf-outputs.json` → Ansible `tf_outputs`.

**`:9443` block** — unchanged. Public access to `*.seven30.xyz` goes through Cloudflare → public gateway → home gateway `:9443` → K8s VIP. With `default_bind 10.0.2.2`, the `:9443` listener binds to the LAN IP, which the public gateway reaches via its subnet route.

**OIDC flow**: When a co-founder visits `gitlab.home.shdr.ch`, GitLab redirects to `auth.shdr.ch` (public, via Cloudflare). After Keycloak auth, the browser is redirected back to `gitlab.home.shdr.ch`, which resolves via their MagicDNS custom record to the Tailscale IP. Seamless.

---

## Gateway API

Add `*.seven30.xyz` listener to the existing main gateway:

```terraform
resource "kubernetes_manifest" "main_gateway" {
  depends_on = [kubernetes_manifest.gateway_class]

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "main-gateway"
      namespace = "default"
      annotations = {
        "io.cilium/lb-ipam-ips" = var.workload_vip
      }
    }
    spec = {
      gatewayClassName = "cilium"
      listeners = [
        {
          name     = "http"
          protocol = "HTTP"
          port     = 80
          hostname = "*.apps.home.shdr.ch"
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        },
        {
          name     = "seven30"
          protocol = "HTTP"
          port     = 80
          hostname = "*.seven30.xyz"
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        }
      ]
    }
  }
}
```

Seven30 apps create HTTPRoutes with `*.seven30.xyz` hostnames. Same VIP (10.0.3.19), different listener.

---

## vcluster

### Why vcluster

Co-founders need to feel like they own their cluster. Namespace isolation is for untrusted tenants.

| Capability | Namespace isolation | vcluster |
| --- | --- | --- |
| Install own CRDs | No | Yes |
| Create namespaces | No | Yes |
| Install Helm charts | Partial | Full |
| Own RBAC | Restricted | Full |
| Break host cluster | Possible | No |

### Single shared vcluster

One vcluster named `seven30`. All 3 people have cluster-admin. Organize with namespaces inside:

```
vcluster: seven30 (host namespace: vc-seven30)
├── project-alpha   (joint project)
├── project-beta    (side project)
├── project-gamma   (side project)
└── shared          (shared DBs, caches)
```

### Resource overhead

~400MB RAM for the vcluster control plane (k3s API server + syncer). Pods run on host cluster nodes, no nested overhead.

### Knative integration

Knative Serving stays on the host cluster. vcluster syncs Knative CRDs (Service, Route, Configuration, Revision) to the host. Seven30 deploys Knative Services inside the vcluster; Knative controller on the host handles scale-to-zero and Gateway API routing.

### kubectl access

vcluster API server exposed as a NodePort or LoadBalancer on the k8s VIP. Caddy proxies it via `k8s.seven30.xyz` on Tailscale only. Kubeconfig:

```yaml
apiVersion: v1
kind: Config
clusters:
  - cluster:
      server: https://k8s.seven30.xyz
    name: seven30
contexts:
  - context:
      cluster: seven30
      user: seven30
    name: seven30
current-context: seven30
users:
  - name: seven30
    user:
      token: <vcluster-generated-token>
```

---

## Keycloak

Seven30 members get Keycloak accounts in the `aether` realm. Used for GitLab OIDC, k8s app auth, and Tailscale SSO.

| Group | Members | Purpose |
| --- | --- | --- |
| `admin` | You | Homelab admin |
| `seven30` | You + 2 co-founders | GitLab + Seven30 app access |

---

## Project Management

No new tools. Just git.

- **Per-project repos** under `seven30` GitLab group — issues, MRs, wiki
- **`seven30` meta-repo** — shared docs, decisions, business tasks as issues

---

## Traffic Flows

### Dev (Tailscale)

```
Seven30 member → Tailscale → Home Gateway (100.x.y.z:443)
  → Caddy (Tailscale bind) → K8s VIP (10.0.3.19) → Gateway API → pod
```

### Prod (Internet)

```
User → Cloudflare (*.seven30.xyz) → Public Caddy (AWS)
  → Home Caddy (:9443) → K8s VIP (10.0.3.19) → Gateway API → pod
```

### kubectl

```
Seven30 member → Tailscale → Home Gateway (100.x.y.z:443)
  → Caddy (k8s.seven30.xyz) → K8s VIP → vcluster API
```

---

## Scaling to Multiple Studios

Node sharing makes this simple. Each studio's members get the same shared device, differentiated by Caddy routes and Keycloak groups.

### Same-trust (both studios share the same Caddy interface)

Both studios' members receive the shared home gateway device. `autogroup:shared` ACL applies to all. Use Keycloak groups + `forward_auth` to control which studio's apps each person can access.

- Network: shared (both reach same Caddy interface via `autogroup:shared`)
- Auth: separated (Keycloak groups per studio)
- Isolation: application-layer only

### Different-trust (studios cannot see each other's routes)

**Option A: Port-based isolation**

Share the same device but use different ports per studio:

```hcl
// ACL: all shared users can reach :443 (Seven30) or :8443 (other studio)
{ action: "accept", src: ["autogroup:shared"], dst: ["tag:home-gateway:443,8443"] },
```

Caddy binds each studio's routes to a different port. Both studios share the device, but see different services. Simple, but `autogroup:shared` can't distinguish between studios by port — you'd need to use tags or separate devices.

**Option B: Separate shared device per studio**

Run a second Tailscale node (container) with its own tag. Share each device only with the relevant studio's members:

```
aether-home-gateway (tag:home-gateway) → shared with Seven30
aether-studio2-proxy (tag:studio2-proxy) → shared with Studio 2
```

Full network isolation, standard ports, `autogroup:shared` scoped per device. More infrastructure, but cleanest separation.

### Recommendation

Start with Seven30 as the only studio. If a second one appears and trust is similar, just share the same device. If trust is different, run a second Tailscale container with its own tag — keeps isolation structural.

---

## Implementation Phases

### Phase 0: Prerequisites (Done)

- [x] Tailscale gateway running with `tag:home-gateway`
- [x] Home gateway has Tailscale IP (`100.76.131.97`)
- [x] `*.seven30.xyz` DNS and public routing wired (Cloudflare → public gateway → `:9443`)
- [x] Gateway API listener for `*.seven30.xyz` added

### Phase 1: Network Isolation (Current)

- [x] Update `tailscale.tf`: scope admin ACL, add `autogroup:shared` rule, add device data source
- [x] Add `home_gateway_tailscale_ip` output to `outputs.tf`
- [x] Add `default_bind 10.0.2.2` to Caddyfile global options
- [x] Add explicit `bind 10.0.2.2 <tailscale_ip>` to GitLab routes
- [ ] `tofu apply` — deploy ACL changes (adds port 53 for `autogroup:shared`)
- [ ] Ansible deploy — update Caddy config + deploy dnsmasq container
- [ ] Verify: all existing LAN routes still work
- [ ] Verify from Tailscale: GitLab reachable, personal services unreachable
- [ ] Verify: `dig @100.76.131.97 gitlab.home.shdr.ch` returns the Tailscale IP

### Phase 2: Onboarding

- [ ] Share `aether-home-gateway` with co-founders via Tailscale admin console
- [ ] Give co-founders the Tailscale IP (`100.76.131.97`) for split DNS setup
- [ ] Co-founders add split DNS in their tailnet: `home.shdr.ch` + `k8s.seven30.xyz` → `100.76.131.97`
- [ ] Keycloak accounts already exist (manually managed)
- [ ] Verify: GitLab OIDC login works end-to-end from co-founder perspective
- [ ] Verify: Grafana/Jellyfin/Proxmox/personal apps unreachable (connection refused)

### Phase 3: Gateway API + vcluster

- [ ] Deploy test HTTPRoute with a Seven30 hostname
- [ ] Verify traffic from both Tailscale and public paths
- [ ] Create `tofu/home/kubernetes/vcluster.tf`
- [ ] Deploy vcluster (name: `seven30`, host namespace: `vc-seven30`)
- [ ] Configure CRD sync (HTTPRoute, Knative)
- [ ] Expose vcluster API (NodePort on k8s VIP)
- [ ] Wire `k8s.seven30.xyz` Caddy route (Tailscale bind)
- [ ] Generate kubeconfig, verify kubectl works

### Phase 4: First Project

- [ ] Create `seven30` group in GitLab
- [ ] Create `seven30` meta-repo
- [ ] Configure GitLab CI for vcluster deploys
- [ ] Deploy first project, verify at `app.seven30.xyz`
- [ ] Expose publicly (already wired — Cloudflare → Caddy → k8s)

---

## Key Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Studio domain | `seven30.xyz` | Already wired with Cloudflare + Caddy |
| Personal domain | `shdr.ch` / `home.shdr.ch` | Clean separation |
| Team size | 3 (you + 2 co-founders) | |
| Multi-tenancy | vcluster | Co-founders need full cluster experience |
| vcluster count | 1 shared | Same-trust, shared services trivial |
| Network access | Tailscale node sharing | Co-founders never join admin tailnet |
| Access isolation | `default_bind` + Tailscale ACL | Deny-by-default at network + proxy layer |
| DNS | Tailscale split DNS + dnsmasq on home gateway | Authoritative-only, no recursion, wildcard *.home.shdr.ch |
| Ports | Standard :443 everywhere | Caddy per-interface bind |
| Admin scope | `tag:home-gateway:*`, `tag:public-gateway:*`, `autogroup:self:*` | No `*:*` even for admin |
| Project management | GitLab native | No new tools |
| Future studios | Node sharing per device or port-based | Depends on trust level |

## Related Documents

- `kubernetes.md` — Host cluster architecture, platform components
- `full-tailscale-integration.md` — Tailscale SSO, gateway auth, ACL structure
- `../trust-model.md` — Identity architecture (Keycloak, OIDC flows)
